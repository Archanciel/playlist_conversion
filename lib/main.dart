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
  const PlaylistConverterApp({super.key});

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
  const ZipPlaylistConverterScreen({super.key});

  @override
  _ZipPlaylistConverterScreenState createState() => _ZipPlaylistConverterScreenState();
}

class _ZipPlaylistConverterScreenState extends State<ZipPlaylistConverterScreen> {
  String _selectedPath = '';
  String _outputPath = '';
  bool _isProcessing = false;
  bool _isBatchMode = false;
  List<String> _logMessages = [];
  int _totalJsonFilesFound = 0;
  int _totalJsonFilesProcessed = 0;
  int _totalAudiosModified = 0;
  int _totalZipFiles = 0;
  int _processedZipFiles = 0;

  void _addLog(String message) {
    setState(() {
      _logMessages.add('${DateTime.now().toString().substring(11, 19)}: $message');
    });
  }

  Future<void> _selectFileOrDirectory() async {
    try {
      // Show dialog to choose between single ZIP or directory
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Mode de sélection'),
          content: Text('Que voulez-vous convertir ?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('file'),
              child: Text('Un fichier ZIP'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('directory'),
              child: Text('Un dossier avec plusieurs ZIP'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Annuler'),
            ),
          ],
        ),
      );

      if (result == null) return;

      if (result == 'file') {
        await _selectSingleZipFile();
      } else {
        await _selectDirectory();
      }
    } catch (e) {
      _addLog('Erreur lors de la sélection: $e');
    }
  }

  Future<void> _selectSingleZipFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result != null && result.files.single.path != null) {
      String selectedPath = result.files.single.path!;

      setState(() {
        _selectedPath = selectedPath;
        _outputPath = selectedPath; // Overwrite original file
        _isBatchMode = false;
        _logMessages.clear();
        _totalJsonFilesFound = 0;
        _totalJsonFilesProcessed = 0;
        _totalAudiosModified = 0;
        _totalZipFiles = 1;
        _processedZipFiles = 0;
      });
      
      _addLog('Fichier ZIP sélectionné: ${path.basename(_selectedPath)}');
      _addLog('Le fichier sera modifié directement (pas de copie)');
    }
  }

  Future<void> _selectDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory != null) {
      // Count ZIP files in directory
      Directory dir = Directory(selectedDirectory);
      List<FileSystemEntity> files = await dir.list().toList();
      List<File> zipFiles = files
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.zip'))
          .toList();

      if (zipFiles.isEmpty) {
        _addLog('Aucun fichier ZIP trouvé dans ce dossier');
        return;
      }

      setState(() {
        _selectedPath = selectedDirectory;
        _outputPath = selectedDirectory;
        _isBatchMode = true;
        _logMessages.clear();
        _totalJsonFilesFound = 0;
        _totalJsonFilesProcessed = 0;
        _totalAudiosModified = 0;
        _totalZipFiles = zipFiles.length;
        _processedZipFiles = 0;
      });
      
      _addLog('Dossier sélectionné: ${path.basename(_selectedPath)}');
      _addLog('Trouvé ${zipFiles.length} fichiers ZIP à traiter');
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
    if (_selectedPath.isEmpty) {
      _addLog('Veuillez sélectionner un fichier ZIP ou un dossier');
      return;
    }

    setState(() {
      _isProcessing = true;
      _logMessages.clear();
      _totalJsonFilesFound = 0;
      _totalJsonFilesProcessed = 0;
      _totalAudiosModified = 0;
      _processedZipFiles = 0;
    });

    _addLog('Début du traitement...');

    try {
      if (_isBatchMode) {
        await _processBatchZipFiles();
      } else {
        await _processSingleZipFile(_selectedPath, _outputPath);
      }
    } catch (e) {
      _addLog('Erreur lors du traitement: $e');
    }

    setState(() {
      _isProcessing = false;
    });

    _addLog('Traitement terminé!');
    if (_isBatchMode) {
      _addLog('Fichiers ZIP traités: $_processedZipFiles/$_totalZipFiles');
    }
    _addLog('Fichiers JSON traités: $_totalJsonFilesProcessed');
    _addLog('Total objets audio modifiés: $_totalAudiosModified');

    if (mounted && _totalAudiosModified > 0) {
      _showCompletionDialog();
    }
  }

  Future<void> _processBatchZipFiles() async {
    Directory dir = Directory(_selectedPath);
    List<FileSystemEntity> files = await dir.list().toList();
    List<File> zipFiles = files
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.zip'))
        .toList();

    _addLog('Traitement de ${zipFiles.length} fichiers ZIP...');

    for (File zipFile in zipFiles) {
      if (!_isProcessing) break;

      String fileName = path.basename(zipFile.path);
      
      _addLog('');
      _addLog('=== Traitement de $fileName ===');

      await _processSingleZipFile(zipFile.path, zipFile.path); // Overwrite original

      setState(() {
        _processedZipFiles++;
      });
    }
  }

  Future<void> _processSingleZipFile(String inputPath, String outputPath) async {
    int currentZipJsonFilesFound = 0;

    // Lire le fichier ZIP
    final bytes = await File(inputPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    
    // Créer une nouvelle archive pour la sortie
    final outputArchive = Archive();
    
    _addLog('ZIP ouvert avec ${archive.length} fichiers');

    // Compter d'abord les fichiers JSON
    for (final file in archive) {
      if (file.name.endsWith('.json') && !file.name.contains('settings.json')) {
        currentZipJsonFilesFound++;
        _totalJsonFilesFound++;
      }
    }
    
    _addLog('Trouvé $currentZipJsonFilesFound fichiers JSON de playlist');

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
    await File(outputPath).writeAsBytes(zipData);
    
    _addLog('✓ Fichier ZIP mis à jour: ${path.basename(outputPath)}');
  }

  void _showCompletionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Conversion Terminée'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isBatchMode) 
                Text('Fichiers ZIP traités: $_processedZipFiles/$_totalZipFiles'),
              Text('Fichiers JSON traités: $_totalJsonFilesProcessed'),
              Text('Objets audio modifiés: $_totalAudiosModified'),
              Text(''),
              Text('Fichier(s) de sortie:'),
              Text(_isBatchMode 
                ? 'Dans le dossier: ${path.basename(_outputPath)}'
                : path.basename(_outputPath), 
                style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          actions: [
            TextButton(
              child: Text('Ouvrir le dossier'),
              onPressed: () {
                Navigator.of(context).pop();
                Process.run('explorer', ['/select,${_isBatchMode ? _outputPath : _outputPath}']);
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

  void _clearLog() {
    setState(() {
      _logMessages.clear();
      _totalJsonFilesFound = 0;
      _totalJsonFilesProcessed = 0;
      _totalAudiosModified = 0;
      _totalZipFiles = 0;
      _processedZipFiles = 0;
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
                    onPressed: _isProcessing ? null : _selectFileOrDirectory,
                    icon: Icon(Icons.archive),
                    label: Text(_selectedPath.isEmpty 
                      ? 'Sélectionner ZIP/Dossier' 
                      : (_isBatchMode 
                          ? '${path.basename(_selectedPath)} ($_totalZipFiles ZIP)'
                          : path.basename(_selectedPath))),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (_isProcessing || _selectedPath.isEmpty) 
                    ? null 
                    : _processZipFile,
                  icon: Icon(Icons.transform),
                  label: Text('Convertir'),
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
                      if (_isBatchMode)
                        Text('Fichiers ZIP: $_processedZipFiles / $_totalZipFiles'),
                      Text('Fichiers JSON: $_totalJsonFilesProcessed / $_totalJsonFilesFound'),
                      Text('$_totalAudiosModified objets audio modifiés'),
                    ],
                  ),
                ),
              ),
            if (_outputPath.isNotEmpty && !_isProcessing)
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Mode:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_isBatchMode ? 'Traitement par lots' : 'Fichier unique'),
                      Text('Sortie:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_isBatchMode 
                        ? 'Dossier: ${path.basename(_outputPath)}'
                        : path.basename(_outputPath)),
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