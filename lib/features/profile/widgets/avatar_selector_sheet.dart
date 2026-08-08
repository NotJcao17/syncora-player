import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_provider.dart';

/// Modal bottom sheet para la selección de avatar basado en Dicebear seeds.
class AvatarSelectorSheet extends ConsumerStatefulWidget {
  final String? currentSeed;
  final ValueChanged<String>? onAvatarSelected;

  const AvatarSelectorSheet({
    super.key,
    this.currentSeed,
    this.onAvatarSelected,
  });

  static const List<String> avatarSeeds = [
    'USER_UUID_PLACEHOLDER',
    'cosmic-wolf',
    'neon-fox',
    'lunar-cat',
    'pixel-dragon',
    'velvet-crow',
    'solar-rabbit',
    'echo-bear',
    'nova-panda',
    'cipher-owl',
    'drift-lynx',
    'flux-tiger',
    'orbit-deer',
    'prism-hawk',
    'quasar-seal',
    'rune-moose',
    'spark-otter',
    'tidal-crane',
    'ultra-mink',
    'vortex-bat',
    'wave-bison',
    'xenon-raven',
    'yield-ferret',
    'zenith-stoat',
  ];

  static Future<void> show(
    BuildContext context, {
    String? currentSeed,
    ValueChanged<String>? onAvatarSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AvatarSelectorSheet(
        currentSeed: currentSeed,
        onAvatarSelected: onAvatarSelected,
      ),
    );
  }

  @override
  ConsumerState<AvatarSelectorSheet> createState() =>
      _AvatarSelectorSheetState();
}

class _AvatarSelectorSheetState extends ConsumerState<AvatarSelectorSheet> {
  late String _selectedSeed;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState() ;
    _selectedSeed = widget.currentSeed ?? '';
  }

  bool _isTestEnvironment() {
    return Platform.environment.containsKey('FLUTTER_TEST');
  }

  Future<void> _handleSelectSeed(String seed, String userId) async {
    setState(() {
      _selectedSeed = seed;
      _isSaving = true;
    });

    try {
      if (!_isTestEnvironment() && userId.isNotEmpty) {
        await Supabase.instance.client
            .from('profiles')
            .update({'avatar_seed': seed}).eq('id', userId);
        ref.invalidate(profileProvider);
      }
      widget.onAvatarSelected?.call(seed);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al actualizar avatar: ${e.toString()}'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    String userId = user?.id ?? '';
    if (userId.isEmpty && !_isTestEnvironment()) {
      try {
        userId = Supabase.instance.client.auth.currentUser?.id ?? '';
      } catch (_) {}
    }
    if (userId.isEmpty) {
      userId = 'default';
    }

    final effectiveSeeds = AvatarSelectorSheet.avatarSeeds.map((seed) {
      return seed == 'USER_UUID_PLACEHOLDER' ? userId : seed;
    }).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: AppTheme.surfaceUpShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Indicator handle
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.surfaceActive,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Sheet Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Elige tu Avatar',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                    letterSpacing: -0.5,
                  ),
                ),
                if (_isSaving)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.accent,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Grid de 24 semillas de avatares
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.0,
              ),
              itemCount: effectiveSeeds.length,
              itemBuilder: (context, index) {
                final seed = effectiveSeeds[index];
                final isSelected = seed == _selectedSeed;
                final avatarUrl =
                    'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed';

                return InkWell(
                  onTap: () => _handleSelectSeed(seed, userId),
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF2C3647)
                            : Colors.transparent,
                        width: isSelected ? 3.5 : 0,
                      ),
                      boxShadow: isSelected ? AppTheme.glowShadow : null,
                    ),
                    padding: const EdgeInsets.all(6),
                    child: ClipOval(
                      child: _isTestEnvironment()
                          ? Container(
                              color: AppTheme.surfaceHover,
                              child: const Icon(
                                Icons.face,
                                color: AppTheme.secondary,
                                size: 28,
                              ),
                            )
                          : SvgPicture.network(
                              avatarUrl,
                              fit: BoxFit.cover,
                              placeholderBuilder: (context) => Container(
                                color: AppTheme.surfaceHover,
                                child: const Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: AppTheme.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
