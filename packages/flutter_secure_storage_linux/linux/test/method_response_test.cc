// Uses Flutter's real value/response types, but no engine, bus or wallet.
#include "../flutter_secure_storage_linux_plugin.cc"

static void malformed_arguments() {
  g_autoptr(FlMethodResponse) absent = create_method_response("read", nullptr);
  g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(absent));
  g_autoptr(FlValue) non_map = fl_value_new_string("invalid");
  g_autoptr(FlMethodResponse) response = create_method_response("read", non_map);
  g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(response));
  g_assert_cmpstr(fl_method_error_response_get_code(FL_METHOD_ERROR_RESPONSE(response)),
                 ==, "Bad arguments");

  for (const char *method : {"write", "read", "delete", "containsKey"}) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "key", fl_value_new_int(42));
    fl_value_set_string_take(args, "value", fl_value_new_bool(TRUE));
    g_autoptr(FlMethodResponse) bad_type = create_method_response(method, args);
    g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(bad_type));
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "key", fl_value_new_string("key"));
  fl_value_set_string_take(args, "value", fl_value_new_int(42));
  g_autoptr(FlMethodResponse) bad_value = create_method_response("write", args);
  g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(bad_value));
  g_autoptr(FlMethodResponse) unknown = create_method_response("unknown", args);
  g_assert_true(FL_IS_METHOD_NOT_IMPLEMENTED_RESPONSE(unknown));
}

static void empty_string_is_not_missing() {
  const nlohmann::json data = {{"empty", ""}, {"normal", "value"}};
  g_autoptr(FlValue) empty = jsonRead(data, "empty");
  g_assert_nonnull(empty);
  g_assert_cmpint(fl_value_get_type(empty), ==, FL_VALUE_TYPE_STRING);
  g_assert_cmpstr(fl_value_get_string(empty), ==, "");
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(empty));
  g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
  g_assert_true(fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response)) == empty);
  g_autoptr(FlValue) missing = jsonRead(data, "missing");
  g_assert_null(missing);
  g_autoptr(FlValue) normal = jsonRead(data, "normal");
  g_assert_cmpstr(fl_value_get_string(normal), ==, "value");
  g_autoptr(FlValue) all = jsonToMap(data);
  g_assert_true(fl_value_equal(fl_value_lookup_string(all, "empty"), empty));
}

static void map_conversion() {
  g_autoptr(FlValue) map = jsonToMap({{"one", "value"}, {"two", "other"}});
  g_assert_cmpuint(fl_value_get_length(map), ==, 2);
  g_assert_cmpstr(fl_value_get_string(fl_value_lookup_string(map, "one")), ==, "value");
  // Throw after a partial map has been allocated/populated. Its auto pointer
  // must release it during unwinding (also suitable for leak-checker runs).
  bool threw = false;
  try {
    g_autoptr(FlValue) invalid = jsonToMap({{"a", "value"}, {"b", 42}});
  } catch (const std::exception &) {
    threw = true;
  }
  g_assert_true(threw);
}

int main(int argc, char **argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/method-response/malformed-arguments", malformed_arguments);
  g_test_add_func("/method-response/map-conversion", map_conversion);
  g_test_add_func("/method-response/empty-string-is-not-missing", empty_string_is_not_missing);
  return g_test_run();
}
