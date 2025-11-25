import 'package:shared_preferences/shared_preferences.dart';

class StorageUtils {
  static const String _emailKey = "user_email";
  static const String _pushKey = "push_enabled";

  /// Save the user's email to local storage
  static Future<void> saveUserEmail(String email) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, email);
  }

  /// Retrieve the user's email from local storage
  static Future<String?> getUserEmail() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_emailKey);
  }

  /// Clear the user's email from local storage
  static Future<void> clearUserEmail() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailKey);
  }

  /// Save the push notification state to local storage
  static Future<void> savePush(bool push) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pushKey, push); // Use setBool for boolean values
  }

  /// Retrieve the push notification state from local storage
  static Future<bool> isPush() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_pushKey) ?? false; // Return false if no value is set
  }
}
