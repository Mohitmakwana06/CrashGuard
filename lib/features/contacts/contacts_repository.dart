/// CrashGuard — Contacts repository (Hive CRUD).
///
/// Provides add / update / delete / getAll operations
/// on the local [kContactsBoxName] Hive box.
library;

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../models/contact_model.dart';

/// Repository for managing [EmergencyContact] persistence.
class ContactsRepository {
  static const _uuid = Uuid();

  /// Returns the opened Hive box.
  Box<EmergencyContact> get _box => Hive.box<EmergencyContact>(kContactsBoxName);

  /// Retrieves all saved contacts.
  List<EmergencyContact> getAll() => _box.values.toList();

  /// Adds a new contact. Returns the created contact.
  Future<EmergencyContact> add({
    required String name,
    required String phone,
  }) async {
    final contact = EmergencyContact(
      id: _uuid.v4(),
      name: name,
      phone: phone,
    );
    await _box.put(contact.id, contact);
    return contact;
  }

  /// Updates an existing contact by [id].
  Future<void> update({
    required String id,
    required String name,
    required String phone,
  }) async {
    final contact = _box.get(id);
    if (contact == null) return;
    contact.name = name;
    contact.phone = phone;
    await contact.save();
  }

  /// Deletes a contact by [id].
  Future<void> delete(String id) async {
    await _box.delete(id);
  }
}
