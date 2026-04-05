/// CrashGuard — Firebase Authentication with Google Sign-In.
///
/// Wraps [FirebaseAuth] and [GoogleSignIn] for authentication,
/// and stores the user profile in Firestore.
library;

import 'dart:developer' as dev;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Authentication result with optional error message.
class AuthResult {
  final bool success;
  final User? user;
  final String? error;
  const AuthResult({required this.success, this.user, this.error});
}

/// Wraps Firebase Authentication and Google Sign-In for the app.
class AuthService {
  AuthService._();

  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  // ─── Public API ────────────────────────────────────────────────────────────

  /// The currently signed-in user (null if signed out).
  static User? get currentUser => _auth.currentUser;

  /// Stream of auth state changes (user sign-in / sign-out).
  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Returns `true` if a user is currently signed in.
  static bool get isSignedIn => _auth.currentUser != null;

  /// Signs in with Google and saves user data to Firestore.
  static Future<AuthResult> signInWithGoogle() async {
    try {
      // 1. Trigger the Google Authentication flow.
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      // 2. Handle user cancellation.
      if (googleUser == null) {
        dev.log('[AuthService] Google sign-in cancelled by user');
        return const AuthResult(
            success: false, error: 'Sign in cancelled by user');
      }

      // 3. Obtain the auth details from the request.
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // 4. Create a new credential for Firebase.
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 5. Sign in to Firebase with the credential.
      final UserCredential userCredential =
          await _auth.signInWithCredential(credential);

      final User? user = userCredential.user;

      if (user != null) {
        dev.log('[AuthService] Sign-in successful: ${user.uid}');
        
        // 6. Save user data to Firestore.
        await _saveUserToFirestore(user);
        
        return AuthResult(success: true, user: user);
      } else {
        return const AuthResult(
            success: false, error: 'Failed to retrieve user information');
      }
    } on FirebaseAuthException catch (e) {
      final message = _mapAuthError(e.code);
      dev.log('[AuthService] Sign-in failed: ${e.code} → $message');
      return AuthResult(success: false, error: message);
    } catch (e) {
      dev.log('[AuthService] Sign-in error: $e');
      return const AuthResult(
          success: false,
          error: 'A network or unexpected error occurred. Please try again.');
    }
  }

  /// Signs out the current user from Firebase and Google.
  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _auth.signOut();
      dev.log('[AuthService] Signed out');
    } catch (e) {
      dev.log('[AuthService] Sign-out error: $e');
    }
  }

  // ─── Internal Storage ──────────────────────────────────────────────────────

  /// Saves the authenticated user securely to Cloud Firestore.
  /// Does not unnecessarily overwrite `createdAt` if it already exists.
  static Future<void> _saveUserToFirestore(User user) async {
    try {
      final userRef = _firestore.collection('users').doc(user.uid);
      final snapshot = await userRef.get();

      if (!snapshot.exists) {
        // User does not exist, create a new record.
        await userRef.set({
          'uid': user.uid,
          'name': user.displayName ?? 'Unknown User',
          'email': user.email ?? '',
          'createdAt': FieldValue.serverTimestamp(),
          // Device linking relies on Realtime Database currently, which operates 
          // side-by-side perfectly with this Firestore user profile.
        });
        dev.log('[AuthService] Created new user profile in Firestore');
      } else {
        // User exists, update fields that might have changed (e.g. name, email) 
        // without touching `createdAt`.
        await userRef.update({
          'name': user.displayName ?? snapshot.data()?['name'] ?? 'Unknown User',
          'email': user.email ?? snapshot.data()?['email'] ?? '',
        });
        dev.log('[AuthService] Updated existing user profile in Firestore');
      }
    } catch (e) {
      // We log the error but do not fail the login process just because Firestore write failed.
      // (This could happen due to temporary network issues, but the user is already authenticated).
      dev.log('[AuthService] Firestore save error: $e');
    }
  }

  // ─── Error Mapping ─────────────────────────────────────────────────────────

  /// Maps Firebase error codes to user-friendly messages.
  static String _mapAuthError(String code) {
    return switch (code) {
      'account-exists-with-different-credential' =>
        'An account already exists with the same email address but different sign-in credentials.',
      'invalid-credential' => 'Invalid credentials.',
      'operation-not-allowed' => 'Google Sign-In is not enabled.',
      'user-disabled' => 'This account has been disabled.',
      'user-not-found' => 'No account found.',
      'wrong-password' => 'Incorrect password.',
      'invalid-verification-code' => 'Invalid verification code.',
      'invalid-verification-id' => 'Invalid verification ID.',
      'network-request-failed' => 'Network error. Please check your connection.',
      _ => 'Authentication failed ($code)',
    };
  }
}
