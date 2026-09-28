#include "FHashTable.hpp"
#include "json.hpp"
#include <gio/gio.h>
#include <libsecret/secret.h>
#include <memory>
#include <stdexcept>
#include <string>

#define secret_autofree _GLIB_CLEANUP(secret_cleanup_free)
static inline void secret_cleanup_free(gchar **p) { secret_password_free(*p); }

// True when the process runs inside a Flatpak or Snap sandbox, where libsecret's
// Simple API (secret_password_*) can route to the portal file backend instead of
// org.freedesktop.secrets.
inline bool isSandboxedContainer(const char *flatpakInfoPath,
                                 const char *snapName) {
  if (snapName != nullptr && snapName[0] != '\0') {
    return true;
  }
  return flatpakInfoPath != nullptr &&
         g_file_test(flatpakInfoPath, G_FILE_TEST_EXISTS);
}

// Whether org.freedesktop.secrets currently has an owner on the session bus.
// A single NameHasOwner call to the bus daemon, far cheaper than
// secret_service_get_sync (no session negotiation, no collection load).
inline bool secretServiceOnSessionBus() {
  g_autoptr(GError) err = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (bus == nullptr) {
    return false;
  }

  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", "org.freedesktop.secrets"), G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NONE, /*timeout_msec=*/1000, nullptr, &err);
  if (reply == nullptr) {
    return false;
  }

  gboolean has_owner = FALSE;
  g_variant_get(reply, "(b)", &has_owner);
  return has_owner;
}

// True when libsecret's Simple API is NOT backed by org.freedesktop.secrets for
// this process, so warmupKeyring (which talks to the Secret Service directly)
// must be skipped.
//
// SECRET_BACKEND is libsecret's own explicit override. Otherwise only a sandbox
// can redirect the Simple API to the portal file backend, and even then only
// when the Secret Service is genuinely unreachable: a snap with the
// password-manager-service interface connected, or a flatpak granted
// --talk-name=org.freedesktop.secrets, still uses the real service, and
// warmupKeyring's missing-alias and lock guards are meaningful there.
inline bool shouldSkipKeyringWarmup(const char *flatpakInfoPath,
                                    const char *snapName,
                                    const char *secretBackendEnv,
                                    bool serviceOnBus) {
  if (secretBackendEnv != nullptr) {
    const std::string preference(secretBackendEnv);
    if (preference == "file") {
      return true;
    }
    if (preference == "service") {
      return false;
    }
  }

  return isSandboxedContainer(flatpakInfoPath, snapName) && !serviceOnBus;
}

inline bool shouldSkipKeyringWarmup() {
  // Neither the sandbox status nor the bus name changes meaningfully over the
  // process lifetime for this purpose, so decide once.
  static const bool skip = shouldSkipKeyringWarmup(
      "/.flatpak-info", g_getenv("SNAP_NAME"), g_getenv("SECRET_BACKEND"),
      secretServiceOnSessionBus());
  return skip;
}

class LibsecretError : public std::runtime_error {
  std::string error_code;

  static const char *codeFromGError(const GError *error) {
    if (error == nullptr) {
      return "Libsecret error";
    }

    if (g_error_matches(error, SECRET_ERROR, SECRET_ERROR_IS_LOCKED)) {
      return "KeyringLocked";
    }

    if (g_error_matches(error, SECRET_ERROR, SECRET_ERROR_NO_SUCH_OBJECT)) {
      return "SecretNotFound";
    }

    return "Libsecret error";
  }

  static std::string messageWithContext(const char *context,
                                        const char *message) {
    if (message == nullptr) {
      return context == nullptr ? "Libsecret error" : context;
    }

    if (context == nullptr || context[0] == '\0') {
      return message;
    }

    std::string result(context);
    result += ": ";
    result += message;
    return result;
  }

public:
  explicit LibsecretError(const char *message)
      : LibsecretError("Libsecret error", message) {}

  LibsecretError(const char *code, const char *message)
      : std::runtime_error(
            message == nullptr
                ? (code == nullptr ? "Libsecret error" : code)
                : message),
        error_code(code == nullptr ? "Libsecret error" : code) {}

  LibsecretError(const char *context, const GError *error)
      : std::runtime_error(messageWithContext(
            context, error == nullptr ? nullptr : error->message)),
        error_code(codeFromGError(error)) {}

  const char *code() const { return error_code.c_str(); }
};

// Discovery must not activate either provider. Only absence (not a denied or
// failed bus query) permits trying the KDE compatibility name. In particular,
// an activatable standard service takes precedence over an already-running KDE
// service. Opening the selected name lets D-Bus perform normal autoactivation.
inline std::string selectSecretServiceName(GDBusConnection *bus) {
  const char *names[] = {"org.freedesktop.secrets",
                         "org.kde.secretservicecompat"};
  g_autoptr(GVariant) activatable = nullptr;
  for (const char *name : names) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) owner = g_dbus_connection_call_sync(
        bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name),
        G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
    if (!owner) {
      throw LibsecretError("Secret Service discovery: NameHasOwner", error);
    }
    gboolean running = FALSE;
    g_variant_get(owner, "(b)", &running);
    if (running) {
      return name;
    }
    if (!activatable) {
      activatable = g_dbus_connection_call_sync(
          bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
          "org.freedesktop.DBus", "ListActivatableNames", nullptr,
          G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
      if (!activatable) {
        throw LibsecretError("Secret Service discovery: ListActivatableNames",
                             error);
      }
    }
    g_autoptr(GVariant) available = g_variant_get_child_value(activatable, 0);
    GVariantIter iter;
    const gchar *candidate = nullptr;
    g_variant_iter_init(&iter, available);
    while (g_variant_iter_next(&iter, "&s", &candidate)) {
      if (g_str_equal(candidate, name)) {
        return name;
      }
    }
  }
  throw LibsecretError("No Secret Service is running or activatable "
                       "(org.freedesktop.secrets or org.kde.secretservicecompat)");
}

// libsecret 0.20.5, 0.21.4 and 0.21.8.2 ignore secret_service_open_sync's bus
// name and their constructor overwrites g-name with the default. This small
// subtype restores the caller's g-name *during construction*, before any I/O.
// No process-global environment override or connection to another wallet.
inline GObject *namedSecretServiceConstructor(
    GType type, guint count, GObjectConstructParam *params) {
  std::string name;
  for (guint i = 0; i < count; ++i) {
    if (g_str_equal(params[i].pspec->name, "g-name")) {
      const char *value = g_value_get_string(params[i].value);
      if (value) name = value;
    }
  }
  auto *parent = G_OBJECT_CLASS(g_type_class_peek(SECRET_TYPE_SERVICE));
  GObject *object = parent->constructor(type, count, params);
  g_object_set(object, "g-name", name.c_str(), nullptr);
  return object;
}

inline SecretService *openNamedSecretService(const char *name,
                                             GError **error) {
  // A construction-only probe detects name replacement without bus access.
  g_autoptr(SecretService) probe = SECRET_SERVICE(g_object_new(
      SECRET_TYPE_SERVICE, "g-name", name,
      "flags", SECRET_SERVICE_OPEN_SESSION, nullptr));
  if (g_strcmp0(g_dbus_proxy_get_name(G_DBUS_PROXY(probe)), name) != 0) {
    static const GType namedType = g_type_register_static_simple(
        SECRET_TYPE_SERVICE, "YunNamedSecretService", sizeof(SecretServiceClass),
        [](gpointer klass, gpointer) {
          G_OBJECT_CLASS(klass)->constructor = namedSecretServiceConstructor;
        }, sizeof(SecretService), nullptr, GTypeFlags(0));
    return SECRET_SERVICE(g_initable_new(
        namedType, nullptr, error, "g-name", name,
        "flags", SECRET_SERVICE_OPEN_SESSION, nullptr));
  }
  // Initialize the very object whose name we verified. Constructor support
  // for g-name does not prove secret_service_open_sync forwards its argument.
  if (!g_initable_init(G_INITABLE(probe), nullptr, error)) return nullptr;
  return g_steal_pointer(&probe);
}

class SecretStorage {
  FHashTable m_attributes;
  std::string service_name;
  std::unique_ptr<SecretService, decltype(&g_object_unref)> service_ {
      nullptr, g_object_unref};
  // Schema identity is selected at construction, not by the display label.
  // Registration default-constructs this object before setting an app label.
  // Never retain label.c_str(): setLabel can invalidate it (including SSO).
  const std::string schema_name;
  std::string label;
  SecretSchema the_schema;

public:
  const char *getLabel() { return label.c_str(); }
  void setLabel(const char *label) { this->label = label; }

  SecretStorage(const char *_label = "default")
      : schema_name(_label), label(_label) {
    the_schema = {schema_name.c_str(),
                  SECRET_SCHEMA_NONE,
                  {
                      {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
                  }};
  }

  // the_schema borrows schema_name's buffer; this owner must not move.
  SecretStorage(const SecretStorage &) = delete;
  SecretStorage &operator=(const SecretStorage &) = delete;
  SecretStorage(SecretStorage &&) = delete;
  SecretStorage &operator=(SecretStorage &&) = delete;

  void addAttribute(const char *key, const char *value) {
    m_attributes.insert(key, value);
  }

  bool addItem(const char *key, const char *value) {
    nlohmann::json root = readFromKeyring();
    root[key] = value;
    return storeToKeyring(root);
  }

  std::string getItem(const char *key) {
    std::string result;
    nlohmann::json root = readFromKeyring();
    nlohmann::json value = root[key];
    if(value.is_string()){
      result = value.get<std::string>();
      return result;
    }
    return "";
  }

  void deleteItem(const char *key) {
    nlohmann::json root = readFromKeyring();
    if (!root.is_object() || !root.contains(key)) {
      return;
    }
    root.erase(key);
    storeToKeyring(root);
  }

  bool deleteKeyring() {
    if (!warmupKeyring()) {
      return true;
    }
    return this->storeToKeyring(nlohmann::json::object());
  }

  bool storeToKeyring(nlohmann::json value) {
    const std::string output = value.dump();
    g_autoptr(GError) err = nullptr;
    bool result;
    if (shouldSkipKeyringWarmup()) {
      // Preserve libsecret's sandbox/explicit file backend routing. Never
      // replace a portal backend with a direct connection to the KDE alias.
      result = secret_password_storev_sync(
          &the_schema, m_attributes.getGHashTable(), nullptr, label.c_str(),
          output.c_str(), nullptr, &err);
    } else {
      warmupKeyring();
      g_autoptr(SecretValue) secret =
          secret_value_new(output.c_str(), output.size(), "text/plain");
      result = secret_service_store_sync(
          service_.get(), &the_schema, m_attributes.getGHashTable(), nullptr,
          label.c_str(), secret, nullptr, &err);
    }

    if (err) {
      throw LibsecretError("store secret", err);
    }

    return result;
  }

  nlohmann::json readFromKeyring() {
    nlohmann::json value = nlohmann::json::object();
    g_autoptr(GError) err = nullptr;

    if (!warmupKeyring()) {
      return value;
    }

    secret_autofree gchar *password = nullptr;
    g_autoptr(SecretValue) secret = nullptr;
    const char *result = nullptr;
    if (shouldSkipKeyringWarmup()) {
      password = secret_password_lookupv_sync(
          &the_schema, m_attributes.getGHashTable(), nullptr, &err);
      result = password;
    } else {
      secret = secret_service_lookup_sync(
          service_.get(), &the_schema, m_attributes.getGHashTable(), nullptr,
          &err);
      if (secret) {
        result = secret_value_get_text(secret);
      }
    }

    if (err) {
      throw LibsecretError("lookup secret", err);
    }
    if(result != NULL && strcmp(result, "") != 0){
      value = nlohmann::json::parse(result);
    }
    return value;
  }

private:
  SecretService *service() {
    if (service_name.empty()) {
      g_autoptr(GError) error = nullptr;
      g_autoptr(GDBusConnection) bus =
          g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
      if (!bus) {
        throw LibsecretError("Secret Service discovery: session bus", error);
      }
      service_name = selectSecretServiceName(bus);
    }
    if (!service_) {
      g_autoptr(GError) error = nullptr;
      service_.reset(openNamedSecretService(service_name.c_str(), &error));
      if (!service_) {
        throw LibsecretError("secret_service_open_sync", error);
      }
    }
    // Pin the name and connection for this storage instance. An error never
    // retries an operation on another store (especially an ambiguous write).
    return service_.get();
  }

  // Ensures the default keyring is accessible and distinguishes a locked
  // collection from other storage errors. A missing default collection is
  // the normal state of a fresh profile, not a locked keyring. Do not load
  // all collections here: some Secret Service backends fail when an
  // unrelated stale item exists in another collection.
  //
  // Skipped when libsecret's Simple API is on the portal file backend (see
  // shouldSkipKeyringWarmup): that backend has no collections to alias or lock,
  // so the guards below don't apply, and secret_password_lookupv_sync /
  // storev_sync still surface a locked backing store as KeyringLocked.
  bool warmupKeyring() {
    if (shouldSkipKeyringWarmup()) {
      return true;
    }

    g_autoptr(GError) err = nullptr;

    SecretService *service = this->service();

    SecretCollection *collection = secret_collection_for_alias_sync(
        service, SECRET_COLLECTION_DEFAULT, SECRET_COLLECTION_NONE, nullptr, &err);

    if (!collection) {
      const bool missingDefaultCollection = err == nullptr;
      if (missingDefaultCollection) {
        g_autoptr(GError) searchError = nullptr;
        GList *matchingItems = secret_service_search_sync(
            service, &the_schema, m_attributes.getGHashTable(),
            SECRET_SEARCH_NONE, nullptr, &searchError);
        const bool hasMatchingItems = matchingItems != nullptr;
        if (matchingItems) {
          g_list_free_full(matchingItems, g_object_unref);
        }

        // With no alias and no matching item this is a fresh profile. If data
        // exists elsewhere, fail closed before a write can create a second
        // default collection and orphan the original item.
        if (searchError) {
          throw LibsecretError("secret_service_search_sync", searchError);
        }
        if (hasMatchingItems) {
          throw LibsecretError("KeyringLocked", "KeyringLocked");
        }
        return false;
      }
      throw LibsecretError("secret_collection_for_alias_sync", err);
    }

    if (!secret_collection_get_locked(collection)) {
      g_object_unref(collection);
      return true;
    }

    GList *to_unlock = g_list_append(nullptr, collection);
    GList *unlocked_out = nullptr;
    gint n = secret_service_unlock_sync(service, to_unlock, nullptr, &unlocked_out, &err);
    g_list_free(to_unlock);
    if (unlocked_out) {
      g_list_free_full(unlocked_out, g_object_unref);
    }
    g_object_unref(collection);

    if (err) {
      throw LibsecretError("secret_service_unlock_sync", err);
    }
    if (n <= 0) {
      throw LibsecretError("KeyringLocked", "KeyringLocked");
    }

    return true;
  }
};
