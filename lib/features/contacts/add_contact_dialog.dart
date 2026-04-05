/// CrashGuard — Add / Edit contact dialog.
///
/// Bottom-sheet form with name + phone validation.
/// Phone field has +91 hint for Indian users.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/contact_model.dart';
import 'contacts_provider.dart';

/// Shows a modal bottom sheet to add or edit an [EmergencyContact].
///
/// If [existing] is provided the form is pre-filled for editing.
void showAddContactDialog({
  required BuildContext context,
  required WidgetRef ref,
  EmergencyContact? existing,
}) {
  final nameController = TextEditingController(text: existing?.name ?? '');
  final phoneController = TextEditingController(text: existing?.phone ?? '');
  final formKey = GlobalKey<FormState>();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final colorScheme = theme.colorScheme;

      return Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle bar.
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Text(
                existing == null ? 'Add Contact' : 'Edit Contact',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This person will be notified via SMS during an accident.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),

              // Name field.
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person_rounded),
                  hintText: 'e.g. Mom, Dad, Friend',
                ),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name is required' : null,
              ),
              const SizedBox(height: 16),

              // Phone field with +91 hint.
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  prefixIcon: Icon(Icons.phone_rounded),
                  hintText: '+919876543210',
                  helperText: 'Include country code (e.g. +91 for India)',
                ),
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Phone is required';
                  // Basic E.164 check.
                  if (!RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(v.trim())) {
                    return 'Enter a valid phone with country code (e.g. +91...)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              FilledButton.icon(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;

                  final name = nameController.text.trim();
                  final phone = phoneController.text.trim();

                  if (existing != null) {
                    ref.read(contactsProvider.notifier).update(
                          id: existing.id,
                          name: name,
                          phone: phone,
                        );
                  } else {
                    ref.read(contactsProvider.notifier).add(
                          name: name,
                          phone: phone,
                        );
                  }

                  Navigator.pop(ctx);
                },
                icon: Icon(existing == null
                    ? Icons.person_add_rounded
                    : Icons.save_rounded),
                label: Text(existing == null ? 'Add Contact' : 'Save Changes'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
