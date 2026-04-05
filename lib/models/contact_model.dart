/// CrashGuard — Emergency contact model with Hive adapter.
///
/// Each contact has a unique [id], a [name], and a [phone] number.
library;

import 'package:hive/hive.dart';

part 'contact_model.g.dart';

/// Hive type ID for [EmergencyContact].
@HiveType(typeId: 0)
class EmergencyContact extends HiveObject {
  /// Unique identifier (UUID v4).
  @HiveField(0)
  final String id;

  /// Contact display name.
  @HiveField(1)
  String name;

  /// Phone number in E.164 format (e.g. +919876543210).
  @HiveField(2)
  String phone;

  EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
  });

  /// Copy-with helper for immutable-style updates.
  EmergencyContact copyWith({String? name, String? phone}) {
    return EmergencyContact(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
    );
  }

  @override
  String toString() => 'EmergencyContact(id: $id, name: $name, phone: $phone)';
}
