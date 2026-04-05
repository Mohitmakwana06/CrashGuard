/// CrashGuard — Contacts providers (Riverpod).
///
/// Exposes [ContactsRepository] CRUD to the widget tree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/contact_model.dart';
import 'contacts_repository.dart';

/// Single instance of the repository.
final contactsRepositoryProvider = Provider<ContactsRepository>(
  (ref) => ContactsRepository(),
);

/// Notifier that holds the list of contacts and handles mutations.
class ContactsNotifier extends StateNotifier<List<EmergencyContact>> {
  final ContactsRepository _repo;

  ContactsNotifier(this._repo) : super(_repo.getAll());

  /// Refreshes state from Hive.
  void refresh() => state = _repo.getAll();

  /// Adds a new contact.
  Future<void> add({required String name, required String phone}) async {
    await _repo.add(name: name, phone: phone);
    refresh();
  }

  /// Updates an existing contact.
  Future<void> update({
    required String id,
    required String name,
    required String phone,
  }) async {
    await _repo.update(id: id, name: name, phone: phone);
    refresh();
  }

  /// Deletes a contact by ID.
  Future<void> delete(String id) async {
    await _repo.delete(id);
    refresh();
  }
}

/// Provider for the contacts notifier.
final contactsProvider =
    StateNotifierProvider<ContactsNotifier, List<EmergencyContact>>((ref) {
  return ContactsNotifier(ref.watch(contactsRepositoryProvider));
});
