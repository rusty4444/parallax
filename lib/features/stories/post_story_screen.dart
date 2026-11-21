import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'stories.dart';

/// Compose and post a 24-hour story (text and/or photo).
class PostStoryScreen extends StatefulWidget {
  const PostStoryScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final StoriesController controller;
  final AppPalette palette;

  @override
  State<PostStoryScreen> createState() => _PostStoryScreenState();
}

class _PostStoryScreenState extends State<PostStoryScreen> {
  final _text = TextEditingController();
  Uint8List? _imageBytes;
  String? _imageName;
  String? _imageMime;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageName = picked.name;
        _imageMime = picked.mimeType ?? 'image/jpeg';
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t pick that photo.');
    }
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty && _imageBytes == null) {
      setState(() => _error = 'Write a story or add a photo first.');
      return;
    }
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      await widget.controller.postStory(
        _text.text,
        imageBytes: _imageBytes,
        imageName: _imageName,
        imageMime: _imageMime,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _posting = false;
          _error = error is StateError
              ? error.message
              : 'Couldn’t post your story. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('New story'),
        backgroundColor: p.background,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const ValueKey('story-text'),
            controller: _text,
            maxLines: 4,
            maxLength: 500,
            enabled: !_posting,
            decoration: const InputDecoration(
              labelText: 'Story',
              hintText: 'Share a moment…',
            ),
          ),
          const SizedBox(height: 8),
          if (_imageBytes != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.memory(_imageBytes!, height: 220, fit: BoxFit.cover),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _posting
                  ? null
                  : () => setState(() {
                      _imageBytes = null;
                      _imageName = null;
                      _imageMime = null;
                    }),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove photo'),
            ),
          ] else
            OutlinedButton.icon(
              key: const ValueKey('story-pick-photo'),
              onPressed: _posting ? null : _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add photo'),
            ),
          const SizedBox(height: 8),
          Text(
            'Stories disappear after 24 hours. They’re end-to-end encrypted '
            'and only visible to people you share them with.',
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: p.accent)),
          ],
          const SizedBox(height: 20),
          AccentButton(
            key: const ValueKey('story-post'),
            palette: p,
            label: _posting ? 'Posting…' : 'Post story',
            icon: Icons.send_rounded,
            onPressed: _posting ? null : _post,
          ),
        ],
      ),
    );
  }
}
