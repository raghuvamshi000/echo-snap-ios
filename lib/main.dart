import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

// Theme Controller
final ValueNotifier<Color> themeNotifier = ValueNotifier(Colors.teal);

final StreamController<bool> refreshStream = StreamController<bool>.broadcast();

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  static Future<void> init(Function(NotificationResponse) onAction) async {
    tz.initializeTimeZones();
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    await _notificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings),
      onDidReceiveNotificationResponse: onAction,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final android = _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'echo_v61_final_alarm_channel',
      'Urgent Med Reminders',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );
    await android?.createNotificationChannel(channel);
  }

  @pragma('vm:entry-point')
  static void notificationTapBackground(NotificationResponse response) async {
    if (response.payload != null && response.actionId == 'taken_action') {
      var data = response.payload!.split('|');
      final db = await openDatabase(p.join(await getDatabasesPath(), 'echo_pill_reminder.db'));
      String now = DateFormat('hh:mm a, dd MMM').format(DateTime.now());

      // Update Stock Logic
      await db.rawUpdate('UPDATE meds SET stockQuantity = stockQuantity - 1 WHERE id = ? AND stockQuantity > 0', [int.parse(data[0])]);
      await db.update('meds', {'lastTaken': 'Taken: $now'}, where: 'id = ?', whereArgs: [int.parse(data[0])]);
      await db.insert('history', {'medName': data[1], 'dateTaken': now, 'type': 'med'});
      refreshStream.add(true);
    }
  }

  static Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? payload,
    String? imagePath,
  }) async {
    var tzDate = tz.TZDateTime.from(scheduledDate, tz.local);
    if (tzDate.isBefore(tz.TZDateTime.now(tz.local))) {
      tzDate = tzDate.add(const Duration(days: 1));
    }

    BigPictureStyleInformation? bigPicture;
    if (imagePath != null && File(imagePath).existsSync()) {
      bigPicture = BigPictureStyleInformation(
        FilePathAndroidBitmap(imagePath),
        largeIcon: FilePathAndroidBitmap(imagePath),
        contentTitle: title,
        summaryText: body,
      );
    }

    await _notificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      tzDate,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'echo_v61_final_alarm_channel',
          'Urgent Med Reminders',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          category: AndroidNotificationCategory.alarm,
          styleInformation: bigPicture,
          additionalFlags: Int32List.fromList([4]),
          actions: [
            const AndroidNotificationAction('taken_action', '✅ MARK AS TAKEN', cancelNotification: true, showsUserInterface: true),
            const AndroidNotificationAction('snooze_action', '⏰ 5 MIN SNOOZE', cancelNotification: true),
          ],
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: payload,
    );
  }

  static Future<void> cancelAllForMed(int mid) async {
    for (int i = 0; i < 20; i++) {
      await _notificationsPlugin.cancel((mid * 100) + i);
    }
    await _notificationsPlugin.cancel((mid * 100) + 99);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EchoHealthApp());
}

class EchoHealthApp extends StatelessWidget {
  const EchoHealthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: themeNotifier,
      builder: (context, currentThemeColor, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: currentThemeColor, primary: currentThemeColor)),
          home: const MainDashboard(),
        );
      },
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  List<Map<String, dynamic>> _medicines = [];
  List<Map<String, dynamic>> _appointments = [];
  List<Map<String, dynamic>> _history = [];

  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer();
  late StreamSubscription _refreshSub;

  @override
  void initState() {
    super.initState();
    _initApp();
    _refreshSub = refreshStream.stream.listen((_) => _refreshData());
  }

  @override
  void dispose() {
    _refreshSub.cancel();
    _textRecognizer.close();
    super.dispose();
  }

  Future<void> _initApp() async {
    await NotificationService.init(_handleNotificationAction);
    await _refreshData();
  }

  Future<Database> _getDatabase() async {
    return openDatabase(
      p.join(await getDatabasesPath(), 'echo_health_v61.db'),
      version: 7,
      onUpgrade: (db, oldV, newV) {
        if (oldV < 7) {
          db.execute('ALTER TABLE history ADD COLUMN type TEXT DEFAULT "med"');
        }
      },
      onCreate: (db, version) {
        db.execute('CREATE TABLE meds(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, alarmTimes TEXT, lastTaken TEXT, imagePath TEXT, stockQuantity INTEGER DEFAULT 30, initialStock INTEGER DEFAULT 30, notes TEXT)');
        db.execute('CREATE TABLE appts(id INTEGER PRIMARY KEY AUTOINCREMENT, docName TEXT, date TEXT, time TEXT)');
        db.execute('CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, medName TEXT, dateTaken TEXT, type TEXT DEFAULT "med")');
      },
    );
  }

  Future<void> _refreshData() async {
    final db = await _getDatabase();
    final m = await db.query('meds', orderBy: 'id DESC');
    final a = await db.query('appts', orderBy: 'id DESC');
    final h = await db.query('history', orderBy: 'id DESC');
    if (mounted) {
      setState(() {
        _medicines = m;
        _appointments = a;
        _history = h;
      });
    }
  }

  void _handleNotificationAction(NotificationResponse response) async {
    if (response.payload == null) return;
    var data = response.payload!.split('|');
    final db = await _getDatabase();
    String now = DateFormat('hh:mm a, dd MMM').format(DateTime.now());

    if (response.actionId == 'taken_action' || response.actionId == null) {
      await db.rawUpdate('UPDATE meds SET stockQuantity = stockQuantity - 1 WHERE id = ? AND stockQuantity > 0', [int.parse(data[0])]);
      await db.update('meds', {'lastTaken': 'Taken: $now'}, where: 'id = ?', whereArgs: [int.parse(data[0])]);
      await db.insert('history', {'medName': data[1], 'dateTaken': now, 'type': 'med'});
      _refreshData();
    } else if (response.actionId == 'snooze_action') {
      NotificationService.scheduleNotification(id: (int.parse(data[0]) * 100) + 99, title: '⏰ SNOOZE: ${data[1]}', body: 'Reminder in 5 minutes', scheduledDate: DateTime.now().add(const Duration(minutes: 5)), payload: response.payload);
    }
  }

  void _exportAllData() async {
    String export = '📋 ECHO PILL REMINDER - DATA EXPORT\n';
    export += 'Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}\n\n';
    export += '💊 ACTIVE MEDICATIONS:\n';
    for (var m in _medicines) {
      export += '- ${m['name']} (Stock: ${m['stockQuantity']}/${m['initialStock']}) Times: ${m['alarmTimes']}\n';
    }
    export += '\n📝 HISTORY LOG:\n';
    for (var h in _history) {
      String type = h['type'] == 'appt' ? '[DOCTOR]' : '[MED]';
      export += '- $type ${h['medName']} at ${h['dateTaken']}\n';
    }
    export += '\n--- END OF REPORT ---\n© 2026 GRV TECH LABS';
    Share.share(export, subject: 'Echo Health Backup');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echo Pill Reminder 💊'),
        backgroundColor: themeNotifier.value,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.bar_chart), onPressed: _showAdherenceReport)],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: themeNotifier.value,
        foregroundColor: Colors.white,
        onPressed: _showMedForm,
        child: const Icon(Icons.add),
      ),
      drawer: Drawer(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              decoration: BoxDecoration(color: themeNotifier.value),
              accountName: const Text('Echo Pill Reminder User'),
              accountEmail: const Text('Secure Local Storage'),
              currentAccountPicture: const CircleAvatar(backgroundColor: Colors.white, child: Icon(Icons.health_and_safety, color: Colors.teal, size: 40)),
            ),
            ListTile(leading: const Icon(Icons.shield_outlined, color: Colors.blue), title: const Text('Permissions Dashboard'), onTap: () {
              Navigator.pop(context);
              _showPermissionDashboard();
            }),
            ListTile(leading: const Icon(Icons.ios_share_rounded, color: Colors.orange), title: const Text('Export My Data'), onTap: () {
              Navigator.pop(context);
              _exportAllData();
            }),
            const Divider(),
            ListTile(leading: const Icon(Icons.lock_outline, color: Colors.green), title: const Text('Privacy Policy'), onTap: () {
              Navigator.pop(context);
              _showPrivacy();
            }),
            ListTile(leading: const Icon(Icons.description_outlined, color: Colors.blueGrey), title: const Text('Terms of Use'), onTap: () {
              Navigator.pop(context);
              _showTerms();
            }),
            const Spacer(),
            const Padding(padding: EdgeInsets.all(16), child: Text('v6.8.0', style: TextStyle(color: Colors.grey))),
          ],
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildLowStockWarning(),
            _actionButtons(),
            _sectionHeader('Medication Schedule'),
            _buildMedList(),
            _sectionHeader('Doctor Visits'),
            _buildApptList(),
            _sectionHeader('Activity History'),
            _buildHistoryList(),
            _sectionHeader('Privacy & Legal'),
            _buildPrivacyAndLegalSection(),
            _buildLegalFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildLowStockWarning() {
    final lowStockMeds = _medicines.where((m) => (m['stockQuantity'] ?? 0) < 5).toList();
    if (lowStockMeds.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.red[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.shade200)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [const Icon(Icons.warning_amber_rounded, color: Colors.red), const SizedBox(width: 8), Text('LOW STOCK ALERT', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red[900]))]),
          ...lowStockMeds.map((m) => Text('• ${m['name']} only has ${m['stockQuantity']} left.', style: const TextStyle(fontSize: 13, color: Colors.black87))),
        ],
      ),
    );
  }

  Widget _actionButtons() => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: ElevatedButton.icon(onPressed: _showMedForm, icon: const Icon(Icons.add), label: const Text('Add Med'))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton.icon(onPressed: _showApptForm, icon: const Icon(Icons.calendar_month), label: const Text('Add Appt'))),
          ],
        ),
      );

  Widget _sectionHeader(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Align(alignment: Alignment.centerLeft, child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: themeNotifier.value))));

  Widget _buildMedList() => ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _medicines.length,
        itemBuilder: (c, i) {
          int current = _medicines[i]['stockQuantity'] ?? 0;
          int total = _medicines[i]['initialStock'] ?? 30;
          double progress = (total > 0) ? (current / total) : 0.0;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: _medicines[i]['imagePath'] != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(File(_medicines[i]['imagePath']), width: 45, height: 45, fit: BoxFit.cover))
                  : const Icon(Icons.medication),
              title: Text(_medicines[i]['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_medicines[i]['notes'] != null && _medicines[i]['notes'].isNotEmpty)
                  Text('📝 ${_medicines[i]['notes']}', style: const TextStyle(color: Colors.blueGrey, fontSize: 12, fontStyle: FontStyle.italic)),
                Text('${_medicines[i]['alarmTimes']}\n${_medicines[i]['lastTaken']}'),
                const SizedBox(height: 8),
                Text('Qty: $current / $total', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: current < 5 ? Colors.red : Colors.black54)),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: progress, backgroundColor: Colors.grey[200], valueColor: AlwaysStoppedAnimation<Color>(current < 5 ? Colors.red : themeNotifier.value), minHeight: 6),
              ]),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.edit, color: Colors.blue), onPressed: () => _showMedForm(existingMed: _medicines[i])),
                IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteMed(_medicines[i]['id'])),
              ]),
            ),
          );
        },
      );

  Widget _buildApptList() => ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _appointments.length,
      itemBuilder: (c, i) => ListTile(
            leading: Icon(Icons.event_available, color: themeNotifier.value),
            title: Text('Dr. ${_appointments[i]['docName']}'),
            subtitle: Text('${_appointments[i]['date']} @ ${_appointments[i]['time']}'),
            trailing: IconButton(
                icon: const Icon(Icons.check_circle, color: Colors.green),
                onPressed: () async {
                  final db = await _getDatabase();
                  String timestamp = DateFormat('hh:mm a, dd MMM').format(DateTime.now());
                  await db.insert('history', {'medName': 'Dr. ${_appointments[i]['docName']}', 'dateTaken': timestamp, 'type': 'appt'});
                  await db.delete('appts', where: 'id = ?', whereArgs: [_appointments[i]['id']]);
                  _refreshData();
                }),
          ));

  Widget _buildHistoryList() => ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _history.length,
      itemBuilder: (c, i) {
        bool isAppt = _history[i]['type'] == 'appt';
        return ListTile(
          dense: true,
          leading: Icon(isAppt ? Icons.medical_services : Icons.check_circle_outline, color: isAppt ? Colors.blue : Colors.green),
          title: Text('${_history[i]['medName']} ${isAppt ? '(Visit Done)' : ''}'),
          subtitle: Text('${isAppt ? 'Completed' : 'Taken'} on: ${_history[i]['dateTaken']}'),
        );
      });

  Widget _buildPrivacyAndLegalSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.lock_outline, color: Colors.green),
              title: const Text('Privacy Policy'),
              subtitle: const Text('Your health data stays on your device.'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _showPrivacy,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.description_outlined, color: Colors.blueGrey),
              title: const Text('Terms of Use'),
              subtitle: const Text('Read responsibilities and app limitations.'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _showTerms,
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.gavel_rounded, color: themeNotifier.value),
              title: const Text('Legal Disclaimer'),
              subtitle: const Text('This app is a reminder aid, not medical advice.'),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _showLegalDisclaimer,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegalFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      color: Colors.grey[100],
      child: Column(children: [
        Icon(Icons.gavel_rounded, color: themeNotifier.value, size: 30),
        const SizedBox(height: 10),
        Text('LEGAL DISCLAIMER & NOTICES', style: TextStyle(fontWeight: FontWeight.bold, color: themeNotifier.value)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Echo Pill Reminder is a medication reminder and tracking tool. It does not provide medical advice, diagnosis, or treatment.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ),
        const Divider(),
        Text('© 2026 GRV TECH LABS PVT. LTD.', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: themeNotifier.value)),
      ]),
    );
  }

  void _showPrivacy() {
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
                title: Row(children: [Icon(Icons.lock, color: themeNotifier.value), const SizedBox(width: 10), const Text('Privacy Policy')]),
                content: const SingleChildScrollView(
                    child: Text(
                        '1. DATA SOVEREIGNTY: You own your data. All records are stored exclusively on your device.\n\n'
                        '2. NO CLOUD STORAGE: Echo Health does not utilize cloud synchronization.\n\n'
                        '3. CAMERA USAGE: Camera access is used only when you choose to scan labels for medicine names.\n\n'
                        '4. SHARING: Reports are shared only when explicitly triggered by you.')),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('CLOSE'))]));
  }

  void _showTerms() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
          title: Row(children: [Icon(Icons.description, color: themeNotifier.value), const SizedBox(width: 10), const Text('Terms of Use')]),
          content: const SingleChildScrollView(
              child: Text(
                  '1. NOT A MEDICAL DEVICE: This software is an informational aid.\n\n'
                  '2. USER VIGILANCE: You are responsible for medicine names, timings, and quantities entered.\n\n'
                  '3. NO GUARANTEE OF OUTCOMES: Notifications may be affected by device settings, battery optimization, or OS restrictions.\n\n'
                  '4. EMERGENCY USE: Do not rely on this application for emergency or critical care decisions.')),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('I AGREE'))]),
    );
  }

  void _showLegalDisclaimer() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Row(children: [Icon(Icons.gavel_rounded, color: themeNotifier.value), const SizedBox(width: 10), const Text('Legal Disclaimer')]),
        content: const SingleChildScrollView(
          child: Text(
              'Echo Pill Reminder is designed to help track medication schedules and appointments.\n\n'
              'It does not provide medical diagnosis, treatment plans, or professional healthcare advice.\n\n'
              'Always consult a licensed medical professional for clinical decisions.'),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('UNDERSTOOD'))],
      ),
    );
  }

  Future<void> _deleteMed(int id) async {
    final db = await _getDatabase();
    await NotificationService.cancelAllForMed(id);
    await db.delete('meds', where: 'id = ?', whereArgs: [id]);
    _refreshData();
  }

  void _showMedForm({Map<String, dynamic>? existingMed}) {
    final nameCtrl = TextEditingController(text: existingMed?['name'] ?? '');
    final stockCtrl = TextEditingController(text: (existingMed?['stockQuantity'] ?? 30).toString());
    final notesCtrl = TextEditingController(text: existingMed?['notes'] ?? '');
    List<TimeOfDay> selectedTimes = [];
    String? path = existingMed?['imagePath'];

    if (existingMed != null) {
      List<String> tStrs = existingMed['alarmTimes'].split(', ');
      for (var s in tStrs) {
        try {
          final parsed = DateFormat.jm().parse(s);
          selectedTimes.add(TimeOfDay(hour: parsed.hour, minute: parsed.minute));
        } catch (e) {
          debugPrint('Time parse error: $e');
        }
      }
    }

    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
            builder: (context, setM) => Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 20, right: 20, top: 20),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    InkWell(
                        onTap: () async {
                          await showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Camera Usage'),
                              content: const Text('This app uses your camera to scan medicine names from labels for setting reminders.'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('OK'),
                                )
                              ],
                            ),
                          );
                          final img = await _picker.pickImage(source: ImageSource.camera);
                          if (img != null) {
                            final res = await _textRecognizer.processImage(InputImage.fromFilePath(img.path));
                            String bestText = '';
                            if (res.blocks.isNotEmpty) {
                              var sorted = List<TextBlock>.from(res.blocks);
                              sorted.sort((a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height));
                              bestText = sorted.first.text.split('\n').first.replaceAll(RegExp(r'\d+mg|\d+ml|Tablets|Capsules', caseSensitive: false), '').trim();
                            }
                            setM(() {
                              path = img.path;
                              if (bestText.isNotEmpty) nameCtrl.text = bestText;
                            });
                          }
                        },
                        child: Container(
                            height: 100,
                            width: double.infinity,
                            decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(10)),
                            child: path == null ? const Icon(Icons.camera_alt) : Image.file(File(path!), fit: BoxFit.contain))),
                    TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Medicine Name')),
                    TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Instructions')),
                    TextField(controller: stockCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stock Quantity')),
                    const SizedBox(height: 10),
                    const Align(alignment: Alignment.centerLeft, child: Text('Alarm Times (Max 4 times)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      children: [
                        ...selectedTimes.map((t) => Chip(label: Text(t.format(context)), onDeleted: () => setM(() => selectedTimes.remove(t)))),
                        if (selectedTimes.length < 4)
                          ActionChip(
                              label: const Text('+ Add Time'),
                              onPressed: () async {
                                final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                                if (t != null) setM(() => selectedTimes.add(t));
                              }),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.value, foregroundColor: Colors.white),
                            onPressed: () async {
                              if (nameCtrl.text.isNotEmpty && selectedTimes.isNotEmpty) {
                                final db = await _getDatabase();
                                String timesStr = selectedTimes.map((t) => t.format(context)).join(', ');
                                int mid;
                                if (existingMed != null) {
                                  mid = existingMed['id'];
                                  await NotificationService.cancelAllForMed(mid);
                                  await db.update('meds', {
                                    'name': nameCtrl.text,
                                    'alarmTimes': timesStr,
                                    'imagePath': path,
                                    'stockQuantity': int.tryParse(stockCtrl.text) ?? 30,
                                    'initialStock': int.tryParse(stockCtrl.text) ?? 30,
                                    'notes': notesCtrl.text
                                  }, where: 'id = ?', whereArgs: [mid]);
                                } else {
                                  mid = await db.insert('meds', {
                                    'name': nameCtrl.text,
                                    'alarmTimes': timesStr,
                                    'lastTaken': 'Pending',
                                    'imagePath': path,
                                    'stockQuantity': int.tryParse(stockCtrl.text) ?? 30,
                                    'initialStock': int.tryParse(stockCtrl.text) ?? 30,
                                    'notes': notesCtrl.text
                                  });
                                }
                                for (int i = 0; i < selectedTimes.length; i++) {
                                  DateTime sched = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, selectedTimes[i].hour, selectedTimes[i].minute);
                                  NotificationService.scheduleNotification(
                                      id: (mid * 100) + i,
                                      title: '💊 TAKE: ${nameCtrl.text}',
                                      body: notesCtrl.text,
                                      scheduledDate: sched,
                                      payload: '$mid|${nameCtrl.text}',
                                      imagePath: path);
                                }
                                _refreshData();
                                Navigator.pop(context);
                              }
                            },
                            child: Text(existingMed == null ? 'SAVE MEDICINE' : 'UPDATE MEDICINE'))),
                    const SizedBox(height: 30),
                  ]),
                )));
  }

  void _showApptForm() {
    final doc = TextEditingController();
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 20, right: 20, top: 20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: doc, decoration: const InputDecoration(labelText: 'Doctor/Clinic Name')),
                ElevatedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime(2030));
                      final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                      if (d != null && t != null && doc.text.isNotEmpty) {
                        final db = await _getDatabase();
                        await db.insert('appts', {'docName': doc.text, 'date': DateFormat('dd MMM').format(d), 'time': t.format(context)});
                        _refreshData();
                        Navigator.pop(context);
                      }
                    },
                    child: const Text('SAVE APPOINTMENT')),
                const SizedBox(height: 30),
              ]),
            ));
  }

  void _showAdherenceReport() {
    int totalTaken = _history.where((h) => h['type'] == 'med').length;
    int totalAppts = _history.where((h) => h['type'] == 'appt').length;
    showModalBottomSheet(
        context: context,
        builder: (context) => Container(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Weekly Health Report', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: themeNotifier.value)),
                const SizedBox(height: 20),
                ListTile(leading: const Icon(Icons.check_circle, color: Colors.green), title: const Text('Total Doses Taken'), trailing: Text('$totalTaken')),
                ListTile(leading: const Icon(Icons.medical_services, color: Colors.blue), title: const Text('Doctor Visits Done'), trailing: Text('$totalAppts')),
                const Divider(),
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                        onPressed: _shareHealthReport,
                        icon: const Icon(Icons.share),
                        label: const Text('SHARE REPORT'),
                        style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.value, foregroundColor: Colors.white))),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('CLOSE')),
              ]),
            ));
  }

  void _shareHealthReport() {
    int medCount = _history.where((h) => h['type'] == 'med').length;
    int apptCount = _history.where((h) => h['type'] == 'appt').length;
    String reportText = '📈 Echo Health Report\nDate: ${DateFormat('dd MMM yyyy').format(DateTime.now())}\n\n✅ Doses Taken: $medCount\n🏥 Visits Completed: $apptCount\n';
    Share.share(reportText);
  }

  void _showPermissionDashboard() {
    showModalBottomSheet(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setP) => Container(
                  padding: const EdgeInsets.all(20),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('System Permissions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 15),
                    FutureBuilder<PermissionStatus>(
                        future: Permission.notification.status,
                        builder: (c, s) => ListTile(
                              leading: Icon(Icons.notifications, color: s.data?.isGranted == true ? Colors.green : Colors.red),
                              title: const Text('Notifications'),
                              trailing: s.data?.isGranted == true
                                  ? const Icon(Icons.check)
                                  : TextButton(
                                      onPressed: () async {
                                        await Permission.notification.request();
                                        setP(() {});
                                      },
                                      child: const Text('FIX')),
                            )),
                    FutureBuilder<PermissionStatus>(
                        future: Permission.scheduleExactAlarm.status,
                        builder: (c, s) => ListTile(
                              leading: Icon(Icons.alarm, color: s.data?.isGranted == true ? Colors.green : Colors.red),
                              title: const Text('Exact Alarms'),
                              trailing: s.data?.isGranted == true
                                  ? const Icon(Icons.check)
                                  : TextButton(
                                      onPressed: () async {
                                        await openAppSettings();
                                      },
                                      child: const Text('OPEN SETTINGS')),
                            )),
                    const SizedBox(height: 20),
                  ]),
                )));
  }
}
