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
      title: 'ZIP Playlist Converter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: ZipPlaylistConverterScreen(),
    );
  }
}

class ZipPlaylistConverterScreen extends StatefulWidget {
  @override
  _ZipPlaylistConverterScreenState createState() => _ZipPlaylistConverterScreenState();
}

class _ZipPlaylistConverterScreenState extends State<ZipPlaylistConverterScreen> {
  String _selectedZipPath = '';
  String _outputZipPath = '';
  bool _isProcessing = false;
  List<String> _logMessages = [];
  int _totalJsonFilesFound = 0;
  int _totalJsonFilesProcessed = 0;
  int _totalAudiosModified = 0;

  void _addLog(String message) {
    setState(() {
      _logMessages.add('${DateTime.now().toString().substring(11, 19)}: $message');
    });
    print(message);
  }

  Future<void> _selectZipFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        String selectedPath = result.files.single.path!;
        String baseName = path.basenameWithoutExtension(selectedPath);
        String directory = path.dirname(selectedPath);
        String outputPath = path.join(directory, '${baseName}_converted.zip');

        setState(() {
          _selectedZipPath = selectedPath;
          _outputZipPath = outputPath;
          _logMessages.clear();
          _totalJsonFilesFound = 0;
          _totalJsonFilesProcessed = 0;
          _totalAudiosModified = 0;
        });
        
        _addLog('Fichier ZIP sélectionné: ${path.basename(_selectedZipPath)}');
        _addLog('Sortie prévue: ${path.basename(_outputZipPath)}');
      }
    } catch (e) {
      _addLog('Erreur lors de la sélection: $e');
    }
  }

  Map<String, dynamic> _convertAudioObject(Map<String, dynamic> audio) {
    if (audio.containsKey('isAudioImported')) {
      bool isImported = audio['isAudioImported'] ?? false;
      audio['audioType'] = isImported ? 'imported' : 'downloaded';
      audio.remove('isAudioImported');
      return audio;
    }
    
    if (!audio.containsKey('audioType')) {
      audio['audioType'] = 'downloaded';
    }
    
    return audio;
  }

  int _processJsonContent(Map<String, dynamic> jsonData) {
    int audioModifiedCount = 0;

    // Process downloadedAudioLst
    if (jsonData['downloadedAudioLst'] is List) {
      List<dynamic> downloadedAudios = jsonData['downloadedAudioLst'];
      for (var audio in downloadedAudios) {
        if (audio is Map<String, dynamic> && audio.containsKey('isAudioImported')) {
          _convertAudioObject(audio);
          audioModifiedCount++;
        }
      }
    }

    // Process playableAudioLst
    if (jsonData['playableAudioLst'] is List) {
      List<dynamic> playableAudios = jsonData['playableAudioLst'];
      for (var audio in playableAudios) {
        if (audio is Map<String, dynamic> && audio.containsKey('isAudioImported')) {
          _convertAudioObject(audio);
          audioModifiedCount++;
        }
      }
    }

    return audioModifiedCount;
  }

  Future<void> _processZipFile() async {
    if (_selectedZipPath.isEmpty) {
      _addLog('Veuillez sélectionner un fichier ZIP');
      return;
    }

    setState(() {
      _isProcessing = true;
      _logMessages.clear();
      _totalJsonFilesFound = 0;
      _totalJsonFilesProcessed = 0;
      _totalAudiosModified = 0;
    });

    _addLog('Début du traitement du fichier ZIP...');

    try {
      // Lire le fichier ZIP
      final bytes = await File(_selectedZipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      
      // Créer une nouvelle archive pour la sortie
      final outputArchive = Archive();
      
      _addLog('ZIP ouvert avec ${archive.length} fichiers');

      // Compter d'abord les fichiers JSON
      for (final file in archive) {
        if (file.name.endsWith('.json') && !file.name.contains('settings.json')) {
          _totalJsonFilesFound++;
        }
      }
      
      _addLog('Trouvé $_totalJsonFilesFound fichiers JSON de playlist');

      // Traiter chaque fichier
      for (final file in archive) {
        if (!_isProcessing) break;

        if (file.isFile) {
          if (file.name.endsWith('.json') && !file.name.contains('settings.json')) {
            // C'est probablement un fichier de playlist
            try {
              final content = utf8.decode(file.content as List<int>);
              final jsonData = json.decode(content) as Map<String, dynamic>;
              
              // Vérifier si c'est vraiment un fichier playlist
              if (jsonData.containsKey('downloadedAudioLst') || jsonData.containsKey('playableAudioLst')) {
                final modifiedCount = _processJsonContent(jsonData);
                
                if (modifiedCount > 0) {
                  // Réécrire le JSON avec les modifications
                  final newContent = JsonEncoder.withIndent('  ').convert(jsonData);
                  final newBytes = utf8.encode(newContent);
                  
                  outputArchive.addFile(ArchiveFile(
                    file.name,
                    newBytes.length,
                    newBytes,
                  ));
                  
                  _addLog('✓ ${path.basename(file.name)}: $modifiedCount audio modifiés');
                  
                  setState(() {
                    _totalJsonFilesProcessed++;
                    _totalAudiosModified += modifiedCount;
                  });
                } else {
                  // Pas de modification, copier tel quel
                  outputArchive.addFile(ArchiveFile(
                    file.name,
                    file.content.length,
                    file.content,
                  ));
                  _addLog('- ${path.basename(file.name)}: aucune modification nécessaire');
                }
              } else {
                // Pas un fichier playlist, copier tel quel
                outputArchive.addFile(ArchiveFile(
                  file.name,
                  file.content.length,
                  file.content,
                ));
              }
            } catch (e) {
              _addLog('Erreur avec ${path.basename(file.name)}: $e');
              // Copier le fichier original en cas d'erreur
              outputArchive.addFile(ArchiveFile(
                file.name,
                file.content.length,
                file.content,
              ));
            }
          } else {
            // Copier tous les autres fichiers tels quels
            outputArchive.addFile(ArchiveFile(
              file.name,
              file.content.length,
              file.content,
            ));
          }
        }
      }

      // Sauvegarder le nouveau ZIP
      final zipData = ZipEncoder().encode(outputArchive);
      await File(_outputZipPath).writeAsBytes(zipData!);
      
      _addLog('✓ Nouveau ZIP sauvegardé: ${path.basename(_outputZipPath)}');

    } catch (e) {
      _addLog('Erreur lors du traitement: $e');
    }

    setState(() {
      _isProcessing = false;
    });

    _addLog('Traitement terminé!');
    _addLog('Fichiers JSON traités: $_totalJsonFilesProcessed/$_totalJsonFilesFound');
    _addLog('Total objets audio modifiés: $_totalAudiosModified');

    if (mounted && _totalAudiosModified > 0) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text('Conversion Terminée'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Fichiers JSON traités: $_totalJsonFilesProcessed'),
                Text('Objets audio modifiés: $_totalAudiosModified'),
                Text(''),
                Text('Fichier de sortie:'),
                Text(path.basename(_outputZipPath), style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            actions: [
              TextButton(
                child: Text('Ouvrir le dossier'),
                onPressed: () {
                  Navigator.of(context).pop();
                  Process.run('explorer', ['/select,${_outputZipPath}']);
                },
              ),
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
      _totalJsonFilesFound = 0;
      _totalJsonFilesProcessed = 0;
      _totalAudiosModified = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Convertisseur ZIP Playlist'),
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
                      'Convertisseur ZIP de Playlists',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(height: 8),
                    Text('Sélectionnez un ZIP contenant les fichiers JSON des playlists'),
                    Text('Conversion: "isAudioImported" → "audioType"'),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _selectZipFile,
                    icon: Icon(Icons.archive),
                    label: Text(_selectedZipPath.isEmpty 
                      ? 'Sélectionner fichier ZIP' 
                      : path.basename(_selectedZipPath)),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (_isProcessing || _selectedZipPath.isEmpty) 
                    ? null 
                    : _processZipFile,
                  icon: Icon(Icons.transform),
                  label: Text('Convertir ZIP'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _clearLog,
                  icon: Icon(Icons.clear),
                  label: Text('Effacer'),
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
                      Text('Traitement en cours... $_totalJsonFilesProcessed / $_totalJsonFilesFound fichiers'),
                      Text('$_totalAudiosModified objets audio modifiés'),
                    ],
                  ),
                ),
              ),
            if (_outputZipPath.isNotEmpty && !_isProcessing)
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fichier de sortie:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(path.basename(_outputZipPath)),
                      Text('Répertoire: ${path.dirname(_outputZipPath)}'),
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
                        'Journal',
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
                                'Sélectionnez un fichier ZIP et cliquez sur Convertir',
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