import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:window_size/window_size.dart';
import 'package:archive/archive.dart';

Future<void> main() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await setWindowsAppSizeAndPosition(
      isTest: true,
    );
  }
  runApp(PlaylistConverterApp());
}

Future<void> setWindowsAppSizeAndPosition({
  required bool isTest,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  await getScreenList().then((List<Screen> screens) {
    final Screen screen = screens.first;
    final Rect screenRect = screen.visibleFrame;

    double windowWidth = (isTest) ? 900 : 730;
    double windowHeight = (isTest) ? 1700 : 1480;

    final double posX = screenRect.right - windowWidth + 10;
    final double posY = (screenRect.height - windowHeight) / 2;

    final Rect windowRect = Rect.fromLTWH(posX, posY, windowWidth, windowHeight);
    setWindowFrame(windowRect);
  });
}

class PlaylistConverterApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Playlist JSON Converter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: PlaylistConverterScreen(),
    );
  }
}

class PlaylistConverterScreen extends StatefulWidget {
  @override
  _PlaylistConverterScreenState createState() => _PlaylistConverterScreenState();
}

class _PlaylistConverterScreenState extends State<PlaylistConverterScreen> {
  String _selectedPath = '';
  bool _isProcessing = false;
  List<String> _logMessages = [];
  int _totalPlaylistsProcessed = 0;
  int _totalAudiosModified = 0;

  void _addLog(String message) {
    setState(() {
      _logMessages.add('${DateTime.now().toString().substring(11, 19)}: $message');
    });
    print(message);
  }

  Future<void> _selectDirectory() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      
      if (selectedDirectory != null) {
        setState(() {
          _selectedPath = selectedDirectory;
          _logMessages.clear();
        });
        _addLog('Selected directory: $_selectedPath');
      }
    } catch (e) {
      _addLog('Error selecting directory: $e');
    }
  }

  Map<String, dynamic> _convertAudioObject(Map<String, dynamic> audio) {
    if (audio.containsKey('isAudioImported')) {
      bool isImported = audio['isAudioImported'] ?? false;
      audio['audioType'] = isImported ? 'imported' : 'downloaded';
      audio.remove('isAudioImported');
      return audio;
    }
    
    // If audioType doesn't exist, set default
    if (!audio.containsKey('audioType')) {
      audio['audioType'] = 'downloaded';
    }
    
    return audio;
  }

  Future<int> _processPlaylistFile(String filePath) async {
    try {
      String content = await File(filePath).readAsString();
      Map<String, dynamic> playlistData = json.decode(content);
      
      int audioModifiedCount = 0;
      bool hasIsAudioImported = false;
      
      // Check downloadedAudioLst
      if (playlistData['downloadedAudioLst'] is List) {
        List<dynamic> downloadedAudios = playlistData['downloadedAudioLst'];
        for (var audio in downloadedAudios) {
          if (audio is Map<String, dynamic> && audio.containsKey('isAudioImported')) {
            hasIsAudioImported = true;
            _convertAudioObject(audio);
            audioModifiedCount++;
          }
        }
      }
      
      // Check playableAudioLst
      if (playlistData['playableAudioLst'] is List) {
        List<dynamic> playableAudios = playlistData['playableAudioLst'];
        for (var audio in playableAudios) {
          if (audio is Map<String, dynamic> && audio.containsKey('isAudioImported')) {
            hasIsAudioImported = true;
            _convertAudioObject(audio);
            audioModifiedCount++;
          }
        }
      }
      
      // Write back only if we found isAudioImported fields
      if (hasIsAudioImported) {
        String modifiedContent = JsonEncoder.withIndent('  ').convert(playlistData);
        await File(filePath).writeAsString(modifiedContent);
        _addLog('Converted $audioModifiedCount audio objects in ${path.basename(filePath)}');
      }
      
      return audioModifiedCount;
    } catch (e) {
      _addLog('Error processing ${path.basename(filePath)}: $e');
      return 0;
    }
  }

  Future<void> _processAllPlaylists() async {
    if (_selectedPath.isEmpty) {
      _addLog('Please select a directory first');
      return;
    }
    
    setState(() {
      _isProcessing = true;
      _totalPlaylistsProcessed = 0;
      _totalAudiosModified = 0;
      _logMessages.clear();
    });
    
    _addLog('Starting conversion...');
    
    try {
      Directory rootDir = Directory(_selectedPath);
      
      await for (FileSystemEntity entity in rootDir.list()) {
        if (!_isProcessing) break;
        
        if (entity is Directory) {
          String playlistName = path.basename(entity.path);
          String jsonFilePath = path.join(entity.path, '$playlistName.json');
          
          if (await File(jsonFilePath).exists()) {
            int modifiedCount = await _processPlaylistFile(jsonFilePath);
            if (modifiedCount > 0) {
              setState(() {
                _totalPlaylistsProcessed++;
                _totalAudiosModified += modifiedCount;
              });
            }
          }
        }
      }
    } catch (e) {
      _addLog('Error processing directory: $e');
    }
    
    setState(() {
      _isProcessing = false;
    });
    
    _addLog('Conversion completed!');
    _addLog('Playlists processed: $_totalPlaylistsProcessed');
    _addLog('Audio objects modified: $_totalAudiosModified');
    
    if (mounted) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text('Conversion Complete'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Playlists processed: $_totalPlaylistsProcessed'),
                Text('Audio objects modified: $_totalAudiosModified'),
              ],
            ),
            actions: [
              TextButton(
                child: Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
    }
  }

  void _clearLog() {
    setState(() {
      _logMessages.clear();
      _totalPlaylistsProcessed = 0;
      _totalAudiosModified = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Playlist JSON Converter'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Convert: "isAudioImported" → "audioType"',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(height: 8),
                    Text('Select the directory containing playlist subdirectories'),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _selectDirectory,
                    icon: Icon(Icons.folder_open),
                    label: Text(_selectedPath.isEmpty ? 'Select Directory' : path.basename(_selectedPath)),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (_isProcessing || _selectedPath.isEmpty) ? null : _processAllPlaylists,
                  icon: Icon(Icons.play_arrow),
                  label: Text('Convert'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _clearLog,
                  icon: Icon(Icons.clear),
                  label: Text('Clear'),
                ),
              ],
            ),
            SizedBox(height: 16),
            if (_isProcessing)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      LinearProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Processing... $_totalPlaylistsProcessed playlists, $_totalAudiosModified audio objects modified'),
                    ],
                  ),
                ),
              ),
            SizedBox(height: 16),
            Expanded(
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        'Log',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: _logMessages.isEmpty
                          ? Center(
                              child: Text(
                                'Select directory and click Convert',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.grey,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _logMessages.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                                  child: Text(
                                    _logMessages[index],
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              },
                            ),
                      ),
                    ),
                    SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}