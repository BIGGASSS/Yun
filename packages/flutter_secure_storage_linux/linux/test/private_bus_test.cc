// Native integration tests: real libsecret, exclusively on GTestDBus.
// The fake service stores dummy secrets in memory; it never opens a host wallet.
#include "../include/Secret.hpp"
#include <glib/gstdio.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static const char *standard = "org.freedesktop.secrets";
static const char *kde = "org.kde.secretservicecompat";
static const char *root_path = "/org/freedesktop/secrets";
static const char *collection_path = "/org/freedesktop/secrets/collection/default";
static const char *item_path = "/org/freedesktop/secrets/collection/default/item1";
static const char *session_path = "/org/freedesktop/secrets/session/test";
static std::string executable;

static const char xml[] = R"XML(
<node>
 <interface name="org.freedesktop.Secret.Service">
  <method name="OpenSession"><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="v" direction="out"/><arg type="o" direction="out"/></method>
  <method name="ReadAlias"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="SearchItems"><arg type="a{ss}" direction="in"/><arg type="ao" direction="out"/><arg type="ao" direction="out"/></method>
  <method name="Unlock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
  <method name="GetSecrets"><arg type="ao" direction="in"/><arg type="o" direction="in"/><arg type="a{o(oayays)}" direction="out"/></method>
  <property name="Collections" type="ao" access="read"/>
 </interface>
 <interface name="org.freedesktop.Secret.Collection">
  <method name="CreateItem"><arg type="a{sv}" direction="in"/><arg type="(oayays)" direction="in"/><arg type="b" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
  <property name="Items" type="ao" access="read"/>
  <property name="Locked" type="b" access="read"/>
  <property name="Label" type="s" access="read"/>
  <property name="Created" type="t" access="read"/>
  <property name="Modified" type="t" access="read"/>
 </interface>
 <interface name="org.freedesktop.Secret.Item">
  <method name="GetSecret"><arg type="o" direction="in"/><arg type="(oayays)" direction="out"/></method>
  <property name="Attributes" type="a{ss}" access="read"/>
  <property name="Locked" type="b" access="read"/>
  <property name="Label" type="s" access="read"/>
  <property name="Created" type="t" access="read"/>
  <property name="Modified" type="t" access="read"/>
 </interface>
 <interface name="org.freedesktop.Secret.Session"><method name="Close"/></interface>
 <interface name="org.yun.Test">
  <method name="Inspect"><arg type="s" direction="out"/><arg type="a{ss}" direction="out"/><arg type="u" direction="out"/><arg type="u" direction="out"/></method>
  <method name="InspectOther"><arg type="s" direction="out"/><arg type="a{ss}" direction="out"/><arg type="u" direction="out"/><arg type="u" direction="out"/></method>
  <method name="DropName"/>
 </interface>
</node>)XML";

static GVariant *paths(const char *path = nullptr) {
  return g_variant_new_objv(path ? &path : nullptr, path ? 1 : 0);
}

struct Mock {
  std::string name;
  std::string mode;
  std::string blob;
  GVariant *attributes = nullptr;
  bool item = false;
  unsigned calls = 0;
  unsigned writes = 0;
  // A second item lets us detect accidental cross-account/schema replacement.
  std::string other_blob;
  GVariant *other_attributes = nullptr;

  static bool matches(GVariant *query, GVariant *attributes) {
    if (!attributes) return false;
    GVariantIter iter;
    g_variant_iter_init(&iter, query);
    const char *key, *value, *stored;
    while (g_variant_iter_next(&iter, "{&s&s}", &key, &value)) {
      if (!g_variant_lookup(attributes, key, "&s", &stored) ||
          !g_str_equal(value, stored)) return false;
    }
    return true;
  }

  bool locked() const { return mode == "locked" || mode == "unlock-denied"; }
  GVariant *secret() {
    return g_variant_new("(o@ay@ays)", session_path,
        g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, nullptr, 0, 1),
        g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, blob.data(), blob.size(), 1),
        "text/plain");
  }
  void seed(const char *schema = "yun.private.test/FlutterSecureStorage",
            const char *account = "yun.private.test.secureStorage") {
    item = true;
    blob = R"({"token":"existing-value","unicode":"你好","other":"preserve"})";
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{ss}"));
    g_variant_builder_add(&b, "{ss}", "account", account);
    g_variant_builder_add(&b, "{ss}", "xdg:schema", schema);
    attributes = g_variant_ref_sink(g_variant_builder_end(&b));
  }
};

static void call(GDBusConnection *connection, const gchar *, const gchar *,
                 const gchar *interface, const gchar *method, GVariant *params,
                 GDBusMethodInvocation *invocation, gpointer data) {
  auto &m = *static_cast<Mock *>(data);
  const std::string op(method);
  if (g_str_equal(interface, "org.yun.Test")) {
    if (op == "Inspect" || op == "InspectOther") {
      GVariant *attrs = op == "Inspect" ? m.attributes : m.other_attributes;
      const std::string &blob = op == "Inspect" ? m.blob : m.other_blob;
      g_dbus_method_invocation_return_value(invocation,
          g_variant_new("(s@a{ss}uu)", blob.c_str(),
              attrs ? g_variant_ref(attrs) :
                  g_variant_new_array(G_VARIANT_TYPE("{ss}"), nullptr, 0),
              m.calls, m.writes));
    } else {
      g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
          connection, "org.freedesktop.DBus", "/org/freedesktop/DBus",
          "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", m.name.c_str()),
          G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
      g_dbus_method_invocation_return_value(invocation, nullptr);
    }
    return;
  }
  ++m.calls;
  if ((m.mode == "denied" && op == "ReadAlias") ||
      (m.mode == "unlock-denied" && op == "Unlock")) {
    g_dbus_method_invocation_return_dbus_error(invocation,
        "org.freedesktop.DBus.Error.AccessDenied", "mock access denied");
    return;
  }
  if ((m.mode == "broken" || m.mode == "timeout" || m.mode == "missing-object") && op == "ReadAlias") {
    g_dbus_method_invocation_return_dbus_error(invocation,
        m.mode == "timeout" ? "org.freedesktop.DBus.Error.TimedOut" :
        m.mode == "missing-object" ? "org.freedesktop.Secret.Error.NoSuchObject" :
        "org.freedesktop.DBus.Error.Failed", "mock broken standard provider");
    return;
  }
  if (op == "OpenSession") {
    const char *algorithm;
    g_variant_get_child(params, 0, "&s", &algorithm);
    if (!g_str_equal(algorithm, "plain")) {
      g_dbus_method_invocation_return_dbus_error(invocation,
          "org.freedesktop.DBus.Error.NotSupported", "test only supports plain sessions");
    } else {
      g_dbus_method_invocation_return_value(invocation,
          g_variant_new("(vo)", g_variant_new_string(""), session_path));
    }
  } else if (op == "ReadAlias") {
    g_dbus_method_invocation_return_value(invocation,
        g_variant_new("(o)", m.mode == "no-alias" || m.mode == "orphan" ? "/" : collection_path));
  } else if (op == "SearchItems") {
    g_autoptr(GVariant) query = g_variant_get_child_value(params, 0);
    // These sentinels must never even match a lookup. Fail before exposing
    // their secrets if the client drops either the account or schema filter.
    g_assert_false(Mock::matches(query, m.other_attributes));
    bool match = m.item && Mock::matches(query, m.attributes);
    g_dbus_method_invocation_return_value(invocation,
        g_variant_new("(@ao@ao)", paths(match && !m.locked() ? item_path : nullptr),
                      paths(match && m.locked() ? item_path : nullptr)));
  } else if (op == "Unlock") {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@aoo)", paths(), "/"));
  } else if (op == "GetSecrets") {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{o(oayays)}"));
    if (m.item) g_variant_builder_add(&b, "{o@(oayays)}", item_path, m.secret());
    g_dbus_method_invocation_return_value(invocation,
        g_variant_new("(@a{o(oayays)})", g_variant_builder_end(&b)));
  } else if (op == "GetSecret") {
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@(oayays))", m.secret()));
  } else if (op == "CreateItem") {
    g_autoptr(GVariant) props = g_variant_get_child_value(params, 0);
    g_autoptr(GVariant) secret = g_variant_get_child_value(params, 1);
    g_autoptr(GVariant) bytes = g_variant_get_child_value(secret, 2);
    gsize size;
    const char *value = static_cast<const char *>(g_variant_get_fixed_array(bytes, &size, 1));
    m.blob.assign(value, size);
    if (m.attributes) g_variant_unref(m.attributes);
    m.attributes = g_variant_lookup_value(props, "org.freedesktop.Secret.Item.Attributes", G_VARIANT_TYPE("a{ss}"));
    g_assert_nonnull(m.attributes);
    // Secret Service replacement is attribute-scoped, not label-scoped.
    g_assert_false(Mock::matches(m.attributes, m.other_attributes));
    const char *account, *label;
    if (g_variant_lookup(m.attributes, "account", "&s", &account) &&
        g_str_equal(account, "app.yun.yun.secureStorage")) {
      g_assert_true(g_variant_lookup(props, "org.freedesktop.Secret.Item.Label", "&s", &label));
      g_assert_cmpstr(label, ==, "app.yun.yun/FlutterSecureStorage");
    }
    gboolean replace = FALSE;
    g_variant_get_child(params, 2, "b", &replace);
    g_assert_true(replace);
    m.item = true;
    ++m.writes;
    // Simulate a committed write whose reply is an error. It must not be
    // repeated, or rerouted to the other service.
    if (m.mode == "ambiguous-write") {
      g_dbus_method_invocation_return_dbus_error(invocation,
          "org.freedesktop.DBus.Error.NoReply", "mock committed write, reply lost");
    } else {
      g_dbus_method_invocation_return_value(invocation, g_variant_new("(oo)", item_path, "/"));
    }
  } else if (op == "Close") {
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else {
    g_error("Unexpected method %s", method);
  }
}

static GVariant *property(GDBusConnection *, const gchar *, const gchar *,
                          const gchar *, const gchar *name, GError **, gpointer data) {
  auto &m = *static_cast<Mock *>(data);
  if (g_str_equal(name, "Collections")) return paths(collection_path);
  if (g_str_equal(name, "Items")) return paths(m.item ? item_path : nullptr);
  if (g_str_equal(name, "Locked")) return g_variant_new_boolean(m.locked());
  if (g_str_equal(name, "Label")) return g_variant_new_string("Private test collection");
  if (g_str_equal(name, "Attributes")) return m.attributes ? g_variant_ref(m.attributes) :
      g_variant_new_array(G_VARIANT_TYPE("{ss}"), nullptr, 0);
  return g_variant_new_uint64(1);
}

static int serve(const char *name, const char *mode) {
  Mock mock;
  mock.name = name;
  mock.mode = mode;
  if (mock.mode == "seed" || mock.mode == "orphan") mock.seed();
  if (mock.mode == "registered-seed" || mock.mode == "registered-corrupt") {
    mock.seed("default", "app.yun.yun.secureStorage");
    if (mock.mode == "registered-corrupt") mock.blob = "not valid JSON";
  }
  if (mock.mode == "other-account" || mock.mode == "other-schema") {
    mock.seed(mock.mode == "other-schema" ? "app.yun.yun/FlutterSecureStorage" : "default",
              mock.mode == "other-account" ? "unrelated.app.secureStorage" : "app.yun.yun.secureStorage");
    mock.other_blob = mock.blob;
    mock.other_attributes = mock.attributes;
    mock.blob.clear();
    mock.attributes = nullptr;
    mock.item = false;
  }
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  g_assert_no_error(error);
  g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(xml, &error);
  g_assert_no_error(error);
  const GDBusInterfaceVTable vtable = {call, property, nullptr, {nullptr}};
  const char *object_paths[] = {root_path, collection_path, item_path, session_path, root_path};
  for (int i = 0; i < 5; ++i) {
    g_assert_cmpuint(g_dbus_connection_register_object(connection, object_paths[i],
        info->interfaces[i], &vtable, &mock, nullptr, &error), >, 0);
    g_assert_no_error(error);
  }
  g_assert_cmpuint(g_dbus_connection_register_object(connection,
      "/org/freedesktop/secrets/aliases/default", info->interfaces[1], &vtable,
      &mock, nullptr, &error), >, 0);
  g_assert_no_error(error);
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(connection,
      "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
      "RequestName", g_variant_new("(su)", name, 0u), G_VARIANT_TYPE("(u)"),
      G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  g_assert_no_error(error);
  guint result;
  g_variant_get(reply, "(u)", &result);
  g_assert_cmpuint(result, ==, 1);
  std::puts("READY");
  std::fflush(stdout);
  g_autoptr(GMainLoop) loop = g_main_loop_new(nullptr, FALSE);
  g_main_loop_run(loop);
  return 0;
}

struct Bus {
  GTestDBus *bus = nullptr;
  GDBusConnection *connection = nullptr;
  std::vector<GSubprocess *> mocks;
  std::string directory;
  std::string activation_file;

  Bus(const char *activate = nullptr, const char *mode = "normal") {
    // GTestDBus creates its own config, without any host service directories.
    // Never use the inherited session bus, including for name discovery.
    g_unsetenv("DBUS_SESSION_BUS_ADDRESS");
    g_unsetenv("SECRET_BACKEND");
    g_unsetenv("SNAP_NAME");
    bus = g_test_dbus_new(G_TEST_DBUS_NONE);
    if (activate) {
      g_autofree gchar *dir = g_dir_make_tmp("yun-secret-activation-XXXXXX", nullptr);
      directory = dir;
      activation_file = directory + "/" + activate + ".service";
      g_autofree gchar *quoted = g_shell_quote(executable.c_str());
      const std::string content = std::string("[D-BUS Service]\nName=") + activate +
          "\nExec=" + quoted + " --mock " + activate + " " + mode + "\n";
      g_assert_true(g_file_set_contents(activation_file.c_str(), content.c_str(), -1, nullptr));
      g_test_dbus_add_service_dir(bus, directory.c_str());
    }
    g_test_dbus_up(bus);
    g_autoptr(GError) error = nullptr;
    connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    g_assert_no_error(error);
    g_assert_nonnull(connection);
  }
  void start(const char *name, const char *mode = "normal") {
    g_autoptr(GError) error = nullptr;
    GSubprocess *process = g_subprocess_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE, &error,
        executable.c_str(), "--mock", name, mode, nullptr);
    g_assert_no_error(error);
    g_autoptr(GDataInputStream) input = g_data_input_stream_new(g_subprocess_get_stdout_pipe(process));
    g_autofree gchar *ready = g_data_input_stream_read_line(input, nullptr, nullptr, &error);
    g_assert_no_error(error);
    g_assert_cmpstr(ready, ==, "READY");
    mocks.push_back(process);
  }
  bool owned(const char *name) {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(connection,
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "NameHasOwner", g_variant_new("(s)", name), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    g_assert_nonnull(reply);
    gboolean running = FALSE;
    g_variant_get(reply, "(b)", &running);
    return running;
  }
  GVariant *inspect(const char *name, const char *method = "Inspect") {
    g_autoptr(GError) error = nullptr;
    GVariant *result = g_dbus_connection_call_sync(connection, name, root_path,
        "org.yun.Test", method, nullptr, G_VARIANT_TYPE("(sa{ss}uu)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
    g_assert_no_error(error);
    return result;
  }
  void untouched(const char *name) {
    g_autoptr(GVariant) state = inspect(name);
    guint calls, writes;
    g_variant_get_child(state, 2, "u", &calls);
    g_variant_get_child(state, 3, "u", &writes);
    g_assert_cmpuint(calls, ==, 0);
    g_assert_cmpuint(writes, ==, 0);
  }
  ~Bus() {
    secret_service_disconnect();
    for (auto *mock : mocks) {
      g_subprocess_force_exit(mock);
      g_subprocess_wait(mock, nullptr, nullptr);
      g_object_unref(mock);
    }
    g_object_unref(connection);
    g_test_dbus_down(bus);
    g_object_unref(bus);
    if (!directory.empty()) {
      g_remove(activation_file.c_str());
      g_rmdir(directory.c_str());
    }
  }
};

static void configure(SecretStorage &storage) {
  storage.addAttribute("account", "yun.private.test.secureStorage");
}

static void checkRoundtrip(Bus &bus, const char *name, SecretStorage &storage,
                           bool seeded, bool registered) {
  if (seeded) {
    g_assert_true(storage.getItem("token") == "existing-value");
    g_assert_true(storage.getItem("unicode") == "你好");
  } else {
    g_assert_true(storage.readFromKeyring().empty());
  }
  g_assert_true(storage.addItem("token", "new-value"));
  g_assert_true(storage.getItem("token") == "new-value");
  g_assert_true(storage.addItem("second", "二"));
  storage.deleteItem("token");
  g_assert_true(storage.getItem("token").empty());
  g_assert_true(storage.getItem("second") == "二");
  if (seeded) g_assert_true(storage.getItem("other") == "preserve");
  g_assert_true(storage.deleteKeyring());
  g_assert_true(storage.readFromKeyring().is_object());
  g_assert_true(storage.readFromKeyring().empty());
  g_autoptr(GVariant) state = bus.inspect(name);
  const char *blob;
  g_variant_get_child(state, 0, "&s", &blob);
  g_assert_cmpstr(blob, ==, "{}");
  g_autoptr(GVariant) attrs = g_variant_get_child_value(state, 1);
  const char *schema, *account;
  g_assert_true(g_variant_lookup(attrs, "xdg:schema", "&s", &schema));
  g_assert_true(g_variant_lookup(attrs, "account", "&s", &account));
  g_assert_cmpstr(schema, ==, registered ? "default" : "yun.private.test/FlutterSecureStorage");
  g_assert_cmpstr(account, ==, registered ? "app.yun.yun.secureStorage" : "yun.private.test.secureStorage");
}

static void roundtrip(Bus &bus, const char *name, bool seeded = false,
                      bool registered = false) {
  if (registered) {
    // EXACT registration order from flutter_secure_storage_linux_plugin.cc:
    // static default construction, setLabel, then the app-specific account.
    SecretStorage storage;
    storage.setLabel("app.yun.yun/FlutterSecureStorage");
    storage.addAttribute("account", "app.yun.yun.secureStorage");
    checkRoundtrip(bus, name, storage, seeded, true);
  } else {
    SecretStorage storage("yun.private.test/FlutterSecureStorage");
    configure(storage);
    checkRoundtrip(bus, name, storage, seeded, false);
  }
}

static void expectError(SecretStorage &storage, const char *code, const char *message) {
  bool caught = false;
  try { storage.addItem("must-not-write", "dummy"); }
  catch (const LibsecretError &error) {
    caught = true;
    g_assert_cmpstr(error.code(), ==, code);
    g_assert_nonnull(g_strstr_len(error.what(), -1, message));
  }
  g_assert_true(caught);
}

static void scenario(gconstpointer data) {
  // Each case gets a fresh process: libsecret and GLib cache bus connections
  // and backend selection. A 20s deadline catches accidental host-bus use.
  if (!g_test_subprocess()) {
    g_test_trap_subprocess(nullptr, 20 * G_USEC_PER_SEC, static_cast<GTestSubprocessFlags>(0));
    g_test_trap_assert_passed();
    return;
  }
  const std::string test(static_cast<const char *>(data));
  const char *activate = test == "kde-activation" ? kde :
      (test == "standard-activation-preferred" || test == "broken-activation") ? standard : nullptr;
  Bus bus(activate, test == "broken-activation" ? "broken" : "normal");
  if (test == "registered-plugin-kde" || test == "registered-plugin-standard" ||
      test == "registered-existing-json" || test == "registered-other-account" ||
      test == "registered-other-schema") {
    const char *name = test == "registered-plugin-standard" ? standard : kde;
    const char *mode = test == "registered-existing-json" ? "registered-seed" :
        test == "registered-other-account" ? "other-account" :
        test == "registered-other-schema" ? "other-schema" : "normal";
    bus.start(name, mode);
    roundtrip(bus, name, test == "registered-existing-json", true);
    if (test == "registered-other-account" || test == "registered-other-schema") {
      g_autoptr(GVariant) state = bus.inspect(name, "InspectOther");
      const char *blob;
      g_variant_get_child(state, 0, "&s", &blob);
      g_assert_cmpstr(blob, ==, R"({"token":"existing-value","unicode":"你好","other":"preserve"})");
    }
  } else if (test == "registered-corrupt-json") {
    bus.start(kde, "registered-corrupt");
    SecretStorage storage;
    storage.setLabel("app.yun.yun/FlutterSecureStorage");
    storage.addAttribute("account", "app.yun.yun.secureStorage");
    bool caught = false;
    try { storage.addItem("token", "must-not-overwrite"); }
    catch (const nlohmann::json::parse_error &) { caught = true; }
    g_assert_true(caught);
    g_autoptr(GVariant) state = bus.inspect(kde);
    const char *blob;
    guint writes;
    g_variant_get_child(state, 0, "&s", &blob);
    g_variant_get_child(state, 3, "u", &writes);
    g_assert_cmpstr(blob, ==, "not valid JSON");
    g_assert_cmpuint(writes, ==, 0);
  } else if (test == "kde-only" || test == "existing-json") {
    g_assert_false(secretServiceOnSessionBus());
    bus.start(kde, test == "existing-json" ? "seed" : "normal");
    g_assert_true(selectSecretServiceName(bus.connection) == kde);
    roundtrip(bus, kde, test == "existing-json");
  } else if (test == "both-prefer-standard" || test == "standard-only") {
    bus.start(standard);
    if (test != "standard-only") bus.start(kde);
    g_assert_true(selectSecretServiceName(bus.connection) == standard);
    roundtrip(bus, standard);
    if (test != "standard-only") bus.untouched(kde);
  } else if (test == "kde-activation") {
    g_assert_false(secretServiceOnSessionBus());
    g_assert_true(selectSecretServiceName(bus.connection) == kde);
    g_assert_false(bus.owned(kde));
    // No manual service start: opening libsecret must autoactivate the mock.
    roundtrip(bus, kde);
  } else if (test == "standard-activation-preferred") {
    bus.start(kde);
    g_assert_false(secretServiceOnSessionBus());
    g_assert_true(selectSecretServiceName(bus.connection) == standard);
    g_assert_false(bus.owned(standard));
    roundtrip(bus, standard);
    bus.untouched(kde);
  } else if (test == "locked-standard" || test == "denied-standard" ||
             test == "broken-standard" || test == "unlock-denied-standard" ||
             test == "broken-activation" || test == "ambiguous-write" ||
             test == "timeout-standard" || test == "missing-object-standard") {
    bus.start(kde);
    if (test != "broken-activation") {
      const char *mode = test == "locked-standard" ? "locked" :
          test == "denied-standard" ? "denied" :
          test == "unlock-denied-standard" ? "unlock-denied" :
          test == "ambiguous-write" ? "ambiguous-write" :
          test == "timeout-standard" ? "timeout" :
          test == "missing-object-standard" ? "missing-object" : "broken";
      bus.start(standard, mode);
    }
    SecretStorage storage("yun.private.test/FlutterSecureStorage");
    configure(storage);
    const char *message = test == "locked-standard" ? "KeyringLocked" :
        test == "denied-standard" || test == "unlock-denied-standard" ? "mock access denied" :
        test == "ambiguous-write" ? "mock committed write" : "mock broken standard";
    expectError(storage, test == "locked-standard" ? "KeyringLocked" :
        test == "missing-object-standard" ? "SecretNotFound" : "Libsecret error", message);
    bus.untouched(kde);
    if (test == "ambiguous-write") {
      g_autoptr(GVariant) state = bus.inspect(standard);
      guint writes;
      g_variant_get_child(state, 3, "u", &writes);
      g_assert_cmpuint(writes, ==, 1);
    }
  } else if (test == "pinned-standard") {
    bus.start(standard);
    bus.start(kde);
    SecretStorage storage("yun.private.test/FlutterSecureStorage");
    configure(storage);
    g_assert_true(storage.addItem("before", "dummy"));
    g_autoptr(GVariant) dropped = g_dbus_connection_call_sync(bus.connection,
        standard, root_path, "org.yun.Test", "DropName", nullptr,
        G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    g_assert_nonnull(dropped);
    g_assert_false(bus.owned(standard));
    // A new discovery would choose KDE; this storage must never reselect it.
    // libsecret may keep using the old unique owner or report its departure.
    try { storage.addItem("after", "dummy"); } catch (const LibsecretError &) {}
    bus.untouched(kde);
  } else if (test == "discovery-failure") {
    bus.start(kde);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GDBusConnection) disconnected = g_dbus_connection_new_for_address_sync(
        g_test_dbus_get_bus_address(bus.bus), GDBusConnectionFlags(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    g_assert_no_error(error);
    g_assert_true(g_dbus_connection_close_sync(disconnected, nullptr, &error));
    g_assert_no_error(error);
    bool caught = false;
    try { selectSecretServiceName(disconnected); }
    catch (const LibsecretError &failure) {
      caught = true;
      g_assert_nonnull(g_strstr_len(failure.what(), -1, "discovery: NameHasOwner"));
    }
    g_assert_true(caught);
    bus.untouched(kde);
  } else if (test == "missing-all") {
    SecretStorage storage;
    expectError(storage, "Libsecret error", "No Secret Service is running or activatable");
  } else if (test == "fresh-no-alias" || test == "orphan-no-alias") {
    bus.start(kde, test == "fresh-no-alias" ? "no-alias" : "orphan");
    SecretStorage storage("yun.private.test/FlutterSecureStorage");
    configure(storage);
    if (test == "fresh-no-alias") {
      g_assert_true(storage.readFromKeyring().empty());
      g_assert_true(storage.deleteKeyring());
    } else {
      expectError(storage, "KeyringLocked", "KeyringLocked");
    }
    g_autoptr(GVariant) state = bus.inspect(kde);
    guint writes;
    g_variant_get_child(state, 3, "u", &writes);
    g_assert_cmpuint(writes, ==, 0);
  } else if (test == "portal-skip" || test == "portal-backend-no-alias") {
    bus.start(kde);
    // The sandbox guard deliberately considers only the standard service.
    // KDE availability must not bypass libsecret's portal/file routing.
    g_setenv("SNAP_NAME", "yun-private-test", TRUE);
    g_assert_true(shouldSkipKeyringWarmup());
    g_assert_true(shouldSkipKeyringWarmup(nullptr, "snap", nullptr, false));
    g_assert_false(shouldSkipKeyringWarmup(nullptr, "snap", nullptr, true));
    g_assert_false(shouldSkipKeyringWarmup(nullptr, "snap", "service", false));
    g_assert_true(shouldSkipKeyringWarmup(nullptr, nullptr, "file", true));
    if (test == "portal-backend-no-alias") {
      // Exercise an actual Simple API call too. There is no portal on this
      // bus: it must fail at the portal, never connect to the KDE service.
      // Isolate all potential file-backend paths from the user's home.
      g_autofree gchar *dir = g_dir_make_tmp("yun-secret-portal-XXXXXX", nullptr);
      g_setenv("XDG_DATA_HOME", dir, TRUE);
      g_setenv("SECRET_BACKEND", "file", TRUE);
      {
        SecretStorage storage("yun.private.test/FlutterSecureStorage");
        configure(storage);
        expectError(storage, "Libsecret error", "org.freedesktop.portal.Desktop");
      }
      g_rmdir(dir);
    }
    bus.untouched(kde);
  } else {
    g_error("Unknown scenario");
  }
}

int main(int argc, char **argv) {
  executable = argv[0];
  if (argc == 4 && g_str_equal(argv[1], "--mock")) return serve(argv[2], argv[3]);
  g_test_init(&argc, &argv, nullptr);
  const char *cases[] = {"registered-plugin-kde", "registered-plugin-standard",
      "registered-existing-json", "registered-other-account", "registered-other-schema",
      "registered-corrupt-json", "kde-only", "existing-json", "both-prefer-standard", "standard-only",
      "kde-activation", "standard-activation-preferred", "locked-standard",
      "denied-standard", "broken-standard", "unlock-denied-standard", "broken-activation",
      "ambiguous-write", "timeout-standard", "missing-object-standard", "pinned-standard",
      "discovery-failure", "missing-all", "fresh-no-alias", "orphan-no-alias", "portal-skip",
      "portal-backend-no-alias"};
  for (const char *test : cases) {
    const std::string path = std::string("/secret-service/") + test;
    g_test_add_data_func(path.c_str(), test, scenario);
  }
  return g_test_run();
}
