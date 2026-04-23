import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

// Branding: Echo Health
final ValueNotifier<Color> themeNotifier = ValueNotifier(Colors.teal);
final StreamController<bool> refreshStream = StreamController<bool>.broadcast();

Future<void> initializeRevenueCat() async {
  String apiKey;
  if (Platform.isIOS) {
    apiKey = 'test_hMKOQepwIOrRNELnVpThruXeEyx';
  } else if (Platform.isAndroid) {
    apiKey = 'test_hMKOQepwIOrRNELnVpThruXeEyx';
  } else {
    throw UnsupportedError('Platform not supported');
  }

  await Purchases.configure(PurchasesConfiguration(apiKey));
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'echo_health_scan_channel';
  static const String _channelName = 'Health Scan Reminders';

  static Future<void> init(Function(NotificationResponse) onAction) async {
    tz.initializeTimeZones();
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/launcher_icon');

    await _notificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings),
      onDidReceiveNotificationResponse: onAction,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final android = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );
    await android?.createNotificationChannel(channel);
  }

  static ({int medId, String medName, int profileId, String profileName})? _parsePayload(
    String? payload,
  ) {
    if (payload == null || payload.trim().isEmpty) return null;
    final data = payload.split('|');
    if (data.length < 2) return null;
    final medId = int.tryParse(data[0]);
    final medName = data[1].trim();
    final profileId = data.length > 2 ? int.tryParse(data[2]) ?? 1 : 1;
    final profileName = data.length > 3 ? data[3].trim() : 'Self';
    if (medId == null || medName.isEmpty) return null;
    return (
      medId: medId,
      medName: medName,
      profileId: profileId,
      profileName: profileName.isEmpty ? 'Self' : profileName,
    );
  }

  @pragma('vm:entry-point')
  static void notificationTapBackground(NotificationResponse response) async {
    try {
      if (response.actionId != 'taken_action') return;
      final parsed = _parsePayload(response.payload);
      if (parsed == null) return;

      final db = await openDatabase(
        p.join(await getDatabasesPath(), 'echo_health.db'),
      );
      final String now = DateFormat('hh:mm a, dd MMM').format(DateTime.now());

      await db.transaction((txn) async {
        await txn.rawUpdate(
          'UPDATE meds SET stockQuantity = stockQuantity - 1 WHERE id = ? AND stockQuantity > 0',
          [parsed.medId],
        );
        await txn.update(
          'meds',
          {'lastTaken': 'Taken: $now'},
          where: 'id = ?',
          whereArgs: [parsed.medId],
        );
        await txn.insert('history', {
          'profileId': parsed.profileId,
          'medName': parsed.medName,
          'dateTaken': now,
          'type': 'med',
        });
      });

      refreshStream.add(true);
    } catch (_) {
      // prevent background tap edge-case crash
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
          _channelId,
          _channelName,
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: false,
          ongoing: false,
          autoCancel: true,
          category: AndroidNotificationCategory.alarm,
          styleInformation: bigPicture,
          actions: [
            const AndroidNotificationAction(
              'taken_action',
              '✅ MARK AS TAKEN',
              cancelNotification: true,
              showsUserInterface: true,
            ),
            const AndroidNotificationAction(
              'snooze_action',
              '⏰ 5 MIN SNOOZE',
              cancelNotification: true,
            ),
          ],
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
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
  await MobileAds.instance.initialize();
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
          title: 'Echo Health Scan',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: currentThemeColor,
              primary: currentThemeColor,
            ),
          ),
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
  static const String _defaultFamilyPromoCode = 'GRV-FAMILY-200';
  static const String _familyPromoCode = _defaultFamilyPromoCode;
  static const String _proEntitlementId = 'pro';
  static const List<Map<String, String>> _bundledHospitalPromotions = [
    {
      'name': 'City Care Hospital',
      'tagline': '24x7 Emergency, ICU and Pharmacy',
      'phone': '+18001234567',
      'website': 'https://www.citycare.example',
    },
    {
      'name': 'Sunrise Children Clinic',
      'tagline': 'Pediatrics, vaccination and growth tracking',
      'phone': '+18001239876',
      'website': 'https://www.sunrisechild.example',
    },
    {
      'name': 'Green Valley Multi-Speciality',
      'tagline': 'Cardio, diabetes and senior-care OPD',
      'phone': '+18004567890',
      'website': 'https://www.greenvalley.example',
    },
    {
      'name': 'Lotus Women Care Center',
      'tagline': 'Maternity, gynecology and newborn care',
      'phone': '+18005678901',
      'website': 'https://www.lotuswomencare.example',
    },
    {
      'name': 'Metro Ortho & Rehab',
      'tagline': 'Orthopedics, physiotherapy and pain clinic',
      'phone': '+18006789012',
      'website': 'https://www.metroortho.example',
    },
  ];
  static const String _developerHospitalFeedJsonUrl =
      'https://echo-health-default-rtdb.firebaseio.com/echo_health_hospital_feed.json';
  static const List<String> _hospitalFeedCandidates = [
    _developerHospitalFeedJsonUrl,
    'https://raw.githubusercontent.com/grvtechlabs/echo-health-feeds/main/hospitals.json',
    'https://example.com/echo-health/hospital-promotions.json',
  ];
  List<Map<String, dynamic>> _medicines = [];
  List<Map<String, dynamic>> _appointments = [];
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _profiles = [];
  List<Map<String, String>> _hospitalPromotions = [];
  int? _activeProfileId;
  bool _isPaidVersion = false;
  bool _revenueCatConfigured = false;
  int _promoUsesLeft = 200;

  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer();
  late StreamSubscription _refreshSub;
  final PageController _hospitalPageController = PageController(viewportFraction: 0.9);
  Timer? _hospitalCarouselTimer;
  int _hospitalPage = 0;

  BannerAd? _bannerAd;
  bool _bannerLoaded = false;

  @override
  void initState() {
    super.initState();
    _initApp();
    _refreshSub = refreshStream.stream.listen((_) => _refreshData());
    _loadBannerAd();
    _startHospitalCarousel();
  }

  @override
  void dispose() {
    _refreshSub.cancel();
    _hospitalCarouselTimer?.cancel();
    _hospitalPageController.dispose();
    _textRecognizer.close();
    _bannerAd?.dispose();
    super.dispose();
  }

  void _loadBannerAd() {
    final banner = BannerAd(
      adUnitId: Platform.isAndroid
          ? 'ca-app-pub-3940256099942544/6300978111'
          : 'ca-app-pub-3940256099942544/2934735716',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) return;
          setState(() {
            _bannerAd = ad as BannerAd;
            _bannerLoaded = true;
          });
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _bannerLoaded = false;
        },
      ),
    );
    banner.load();
  }

  void _startHospitalCarousel() {
    _hospitalCarouselTimer?.cancel();
    _hospitalCarouselTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || _hospitalPromotions.length < 2 || !_hospitalPageController.hasClients) {
        return;
      }
      final next = (_hospitalPage + 1) % _hospitalPromotions.length;
      _hospitalPageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  Future<void> _initApp() async {
    await NotificationService.init(_handleNotificationAction);
    await _loadProfilesAndSettings();
    await _initRevenueCat();
    await _refreshHospitalFeed();
    await _refreshData();
  }

  Future<Database> _getDatabase() async {
    return openDatabase(
      p.join(await getDatabasesPath(), 'echo_health.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE profiles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, color INTEGER)',
        );
        await db.execute(
          'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)',
        );
        await db.insert('profiles', {'name': 'Self', 'color': Colors.teal.value});
        await db.insert('settings', {'key': 'paid_version', 'value': 'false'});
        await db.insert('settings', {'key': 'promo_uses_left', 'value': '200'});
        await db.execute(
          'CREATE TABLE meds(id INTEGER PRIMARY KEY AUTOINCREMENT, profileId INTEGER DEFAULT 1, name TEXT, alarmTimes TEXT, lastTaken TEXT, imagePath TEXT, stockQuantity INTEGER DEFAULT 30, initialStock INTEGER DEFAULT 30, notes TEXT)',
        );
        await db.execute(
          'CREATE TABLE appts(id INTEGER PRIMARY KEY AUTOINCREMENT, profileId INTEGER DEFAULT 1, docName TEXT, date TEXT, time TEXT)',
        );
        await db.execute(
          'CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, profileId INTEGER DEFAULT 1, medName TEXT, dateTaken TEXT, type TEXT DEFAULT "med")',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, color INTEGER)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT)',
          );
          await db.execute(
            'ALTER TABLE meds ADD COLUMN profileId INTEGER DEFAULT 1',
          );
          await db.execute(
            'ALTER TABLE appts ADD COLUMN profileId INTEGER DEFAULT 1',
          );
          await db.execute(
            'ALTER TABLE history ADD COLUMN profileId INTEGER DEFAULT 1',
          );
          final profileCount = Sqflite.firstIntValue(
                await db.rawQuery('SELECT COUNT(*) FROM profiles'),
              ) ??
              0;
          if (profileCount == 0) {
            await db.insert('profiles', {'name': 'Self', 'color': Colors.teal.value});
          }
          await db.insert(
            'settings',
            {'key': 'paid_version', 'value': 'false'},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          await db.insert(
            'settings',
            {'key': 'promo_uses_left', 'value': '200'},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      },
    );
  }

  Future<void> _loadProfilesAndSettings() async {
    final db = await _getDatabase();
    final profiles = await db.query('profiles', orderBy: 'id ASC');
    final paidSetting = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['paid_version'],
      limit: 1,
    );
    final promoSetting = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['promo_uses_left'],
      limit: 1,
    );
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeProfileId = profiles.isNotEmpty ? profiles.first['id'] as int : 1;
      _isPaidVersion =
          paidSetting.isNotEmpty && (paidSetting.first['value'] == 'true');
      _promoUsesLeft = promoSetting.isNotEmpty
          ? int.tryParse(promoSetting.first['value'].toString()) ?? 200
          : 200;
    });
  }

  Future<void> _refreshData() async {
    final db = await _getDatabase();
    final where = _activeProfileId == null ? null : 'profileId = ?';
    final whereArgs = _activeProfileId == null ? null : [_activeProfileId];
    final m = await db.query(
      'meds',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
    final a = await db.query(
      'appts',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
    final h = await db.query(
      'history',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
    if (mounted) {
      setState(() {
        _medicines = m;
        _appointments = a;
        _history = h;
      });
    }
  }

  void _handleNotificationAction(NotificationResponse response) async {
    try {
      final parsed = NotificationService._parsePayload(response.payload);
      if (parsed == null) return;

      final db = await _getDatabase();
      final String now = DateFormat('hh:mm a, dd MMM').format(DateTime.now());

      if (response.actionId == 'taken_action' || response.actionId == null) {
        await db.transaction((txn) async {
          await txn.rawUpdate(
            'UPDATE meds SET stockQuantity = stockQuantity - 1 WHERE id = ? AND stockQuantity > 0',
            [parsed.medId],
          );
          await txn.update(
            'meds',
            {'lastTaken': 'Taken: $now'},
            where: 'id = ?',
            whereArgs: [parsed.medId],
          );
          await txn.insert('history', {
            'profileId': parsed.profileId,
            'medName': parsed.medName,
            'dateTaken': now,
            'type': 'med',
          });
        });
        _refreshData();
      } else if (response.actionId == 'snooze_action') {
        NotificationService.scheduleNotification(
          id: (parsed.medId * 100) + 99,
          title: '⏰ SNOOZE: ${parsed.medName} (${parsed.profileName})',
          body: 'Reminder for ${parsed.profileName} in 5 minutes',
          scheduledDate: DateTime.now().add(const Duration(minutes: 5)),
          payload: response.payload,
        );
      }
    } catch (_) {
      // prevent app crash for malformed/legacy notification payloads
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echo Health 💊'),
        backgroundColor: themeNotifier.value,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            onPressed: _showAdherenceReport,
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'apptBtn',
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            onPressed: () => _showApptForm(),
            child: const Icon(Icons.person_add_alt_1),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'medBtn',
            backgroundColor: themeNotifier.value,
            foregroundColor: Colors.white,
            onPressed: () => _showMedForm(),
            child: const Icon(Icons.add),
          ),
        ],
      ),
      drawer: Drawer(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              decoration: BoxDecoration(color: themeNotifier.value),
              accountName: const Text('Echo Health'),
              accountEmail: const Text('Secure Offline Storage'),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  Icons.qr_code_scanner,
                  color: Colors.teal,
                  size: 40,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('Permissions'),
              onTap: () {
                Navigator.pop(context);
                _showPermissionDashboard();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Export Backup'),
              onTap: () {
                Navigator.pop(context);
                _exportAllData();
              },
            ),
            ListTile(
              leading: const Icon(Icons.workspace_premium),
              title: const Text('Purchase / Redeem'),
              onTap: () {
                Navigator.pop(context);
                _showUpgradePurchaseDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_hospital),
              title: const Text('Refresh Hospital Feed'),
              onTap: () {
                Navigator.pop(context);
                _refreshHospitalFeed(showStatus: true);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Privacy Policy'),
              onTap: () {
                Navigator.pop(context);
                _showPrivacy();
              },
            ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'Developed by GRV TECH LABS',
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '© 2026 GRV TECH LABS',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              _buildProfileSelector(),
              _buildProFeaturesPanel(),
              _buildHospitalPromotions(),
              _buildLowStockWarning(),
              _sectionHeader('Medication Schedule'),
              _buildMedList(),
              _sectionHeader('Doctor Visits'),
              _buildApptList(),
              _sectionHeader('Activity History'),
              _buildHistoryList(),
              if (_bannerLoaded && _bannerAd != null)
                SizedBox(
                  width: _bannerAd!.size.width.toDouble(),
                  height: _bannerAd!.size.height.toDouble(),
                  child: AdWidget(ad: _bannerAd!),
                ),
              _buildLegalFooter(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLowStockWarning() {
    final lowStockMeds =
        _medicines.where((m) => (m['stockQuantity'] ?? 0) < 5).toList();
    if (lowStockMeds.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '⚠️ LOW STOCK ALERT',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
          ),
          ...lowStockMeds.map(
            (m) => Text(
              '• ${m['name']} is running low (${m['stockQuantity']} left).',
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: themeNotifier.value,
            ),
          ),
        ),
      );

  Widget _buildProfileSelector() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Card(
          child: ListTile(
            leading: const Icon(Icons.family_restroom),
            title: const Text('Active Family Profile'),
            subtitle: DropdownButton<int>(
              value: _activeProfileId,
              isExpanded: true,
              items: _profiles
                  .map(
                    (p) => DropdownMenuItem<int>(
                      value: p['id'] as int,
                      child: Text(p['name'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) return;
                setState(() => _activeProfileId = value);
                await _refreshData();
              },
            ),
            trailing: IconButton(
              icon: Icon(
                _isPaidVersion ? Icons.workspace_premium : Icons.lock_outline,
                color: themeNotifier.value,
              ),
              onPressed: _showUpgradePurchaseDialog,
            ),
          ),
        ),
      );

  String _activeProfileName() {
    if (_activeProfileId == null) return 'Self';
    final found = _profiles.where((p) => p['id'] == _activeProfileId);
    if (found.isEmpty) return 'Self';
    return found.first['name']?.toString() ?? 'Self';
  }

  Widget _buildProFeaturesPanel() {
    final int missedToday = _calculateMissedDosesToday();
    final List<Map<String, dynamic>> lowRefill = _refillPredictions();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.stars, color: themeNotifier.value),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Paid Version Features',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const SizedBox(height: 2),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: Text('Missed Today: $missedToday'),
                    onPressed: _isPaidVersion ? _showMissedDoseSummary : _showPaidOnlyDialog,
                  ),
                  ActionChip(
                    label: Text('Refill Alerts: ${lowRefill.length}'),
                    onPressed: _isPaidVersion ? _showRefillPredictions : _showPaidOnlyDialog,
                  ),
                  ActionChip(
                    label: const Text('Backup / Restore'),
                    onPressed:
                        _isPaidVersion ? _showBackupRestoreSheet : _showPaidOnlyDialog,
                  ),
                  ActionChip(
                    label: const Text('Calendar Timeline'),
                    onPressed: _isPaidVersion ? _showCalendarTimeline : _showPaidOnlyDialog,
                  ),
                  ActionChip(
                    label: const Text('Family Profiles'),
                    onPressed: _isPaidVersion ? _showFamilyProfileManager : _showPaidOnlyDialog,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _calculateMissedDosesToday() {
    final now = DateTime.now();
    int scheduled = 0;
    for (final med in _medicines) {
      final times = (med['alarmTimes'] ?? '').toString();
      if (times.trim().isEmpty) continue;
      for (final t in times.split(',')) {
        try {
          final parsed = DateFormat('h:mm a').parseLoose(t.trim());
          final sched = DateTime(now.year, now.month, now.day, parsed.hour, parsed.minute);
          if (sched.isBefore(now)) scheduled++;
        } catch (_) {}
      }
    }
    final takenToday = _history.where((h) => (h['dateTaken'] ?? '').toString().contains(DateFormat('dd MMM').format(now))).length;
    final missed = scheduled - takenToday;
    return missed < 0 ? 0 : missed;
  }

  List<Map<String, dynamic>> _refillPredictions() {
    final List<Map<String, dynamic>> predictions = [];
    for (final med in _medicines) {
      final times = (med['alarmTimes'] ?? '').toString();
      final countPerDay = times.trim().isEmpty ? 1 : times.split(',').length;
      final stock = med['stockQuantity'] ?? 0;
      final daysLeft = countPerDay == 0 ? stock : (stock / countPerDay).floor();
      if (daysLeft <= 3) {
        predictions.add({'name': med['name'], 'daysLeft': daysLeft, 'stock': stock});
      }
    }
    return predictions;
  }

  void _loadBundledHospitalPromotions({bool shuffle = false}) {
    final list = List<Map<String, String>>.from(_bundledHospitalPromotions);
    if (shuffle) list.shuffle();
    if (!mounted) return;
    setState(() {
      _hospitalPromotions = list;
      _hospitalPage = 0;
    });
  }

  List<Map<String, String>> _parseHospitalFeed(dynamic decoded) {
    if (decoded is Map) {
      return decoded.values
          .map(
            (e) => {
              'name': (e['name'] ?? '').toString(),
              'tagline': (e['tagline'] ?? '').toString(),
              'phone': (e['phone'] ?? '').toString(),
              'website': (e['website'] ?? '').toString(),
            },
          )
          .where((e) => e['name']!.trim().isNotEmpty)
          .take(5)
          .toList();
    }
    if (decoded is! List) return const [];
    return decoded
        .map(
          (e) => {
            'name': (e['name'] ?? '').toString(),
            'tagline': (e['tagline'] ?? '').toString(),
            'phone': (e['phone'] ?? '').toString(),
            'website': (e['website'] ?? '').toString(),
          },
        )
        .where((e) => e['name']!.trim().isNotEmpty)
        .take(5)
        .toList();
  }

  Future<List<Map<String, String>>> _fetchHospitalFeedFromUrl(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final decoded = jsonDecode(body);
      return _parseHospitalFeed(decoded);
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  Future<void> _refreshHospitalFeed({bool showStatus = false}) async {
    for (final url in _hospitalFeedCandidates) {
      final parsed = await _fetchHospitalFeedFromUrl(url);
      if (parsed.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _hospitalPromotions = parsed;
          _hospitalPage = 0;
        });
        if (showStatus) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Hospital feed updated (${parsed.length} listings).'),
            ),
          );
        }
        return;
      }
    }
    _loadBundledHospitalPromotions(shuffle: true);
    if (showStatus && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Live hospital feed unavailable. Showing bundled directory.',
          ),
        ),
      );
    }
  }

  Widget _buildHospitalPromotions() {
    if (_hospitalPromotions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Card(
        color: Colors.orange[50],
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.local_hospital, color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  const Text(
                    'Promoted Hospitals',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Developer-managed JSON campaign feed (same for all installers).',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 160,
                child: PageView.builder(
                  controller: _hospitalPageController,
                  itemCount: _hospitalPromotions.length,
                  onPageChanged: (index) => setState(() => _hospitalPage = index),
                  itemBuilder: (context, index) {
                    final h = _hospitalPromotions[index];
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  h['name'] ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  h['tagline'] ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Call',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openUri('tel:${h['phone']}'),
                                icon: const Icon(Icons.call, color: Colors.green, size: 22),
                              ),
                              IconButton(
                                tooltip: 'Website',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openUri(h['website'] ?? ''),
                                icon: const Icon(Icons.open_in_new, color: Colors.blue, size: 22),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_hospitalPromotions.length, (index) {
                  final active = index == _hospitalPage;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: active ? 14 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: active ? Colors.orange : Colors.orange.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUri(String uri) async {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return;
    await launchUrl(parsed, mode: LaunchMode.externalApplication);
  }

  Widget _buildMedList() => ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _medicines.length,
        itemBuilder: (c, i) {
          final int current = _medicines[i]['stockQuantity'] ?? 0;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: _medicines[i]['imagePath'] != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(_medicines[i]['imagePath']),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(Icons.medication),
              title: Text(
                _medicines[i]['name'],
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${_displayAlarmTimes(_medicines[i]['alarmTimes']?.toString())}\nStock: $current',
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'edit') {
                    _showMedForm(existingMed: _medicines[i]);
                  } else if (value == 'delete') {
                    _deleteMed(_medicines[i]['id']);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit, color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Text('Edit timing'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red, size: 18),
                        SizedBox(width: 8),
                        Text('Delete'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

  Widget _buildApptList() => ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _appointments.length,
        itemBuilder: (c, i) => Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.event, color: Colors.orange),
            title: Text('Dr. ${_appointments[i]['docName']}'),
            subtitle: Text(
              '${_appointments[i]['date']} @ ${_appointments[i]['time']}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final db = await _getDatabase();
                await db.delete(
                  'appts',
                  where: 'id = ?',
                  whereArgs: [_appointments[i]['id']],
                );
                _refreshData();
              },
            ),
          ),
        ),
      );

  Widget _buildHistoryList() => ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _history.length > 5 ? 5 : _history.length,
        itemBuilder: (c, i) => ListTile(
          dense: true,
          leading: const Icon(Icons.check, color: Colors.green),
          title: Text(_history[i]['medName']),
          subtitle: Text(_history[i]['dateTaken']),
        ),
      );

  Widget _buildLegalFooter() => Container(
        padding: const EdgeInsets.all(24),
        color: Colors.grey[100],
        width: double.infinity,
        child: Column(
          children: [
            Icon(Icons.gavel_rounded, color: themeNotifier.value, size: 44),
            const SizedBox(height: 8),
            Text(
              'LEGAL DISCLAIMER',
              style: TextStyle(
                fontSize: 34 / 2,
                color: themeNotifier.value,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Echo Health is a schedule reminder tool. It does not provide medical advice. GRV TECH LABS is not responsible for missed medications. Always consult a doctor before changing dosages.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54, height: 1.5),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _showPrivacy,
                  child: Text(
                    'Privacy',
                    style: TextStyle(color: themeNotifier.value, fontSize: 16),
                  ),
                ),
                const Text('|', style: TextStyle(fontSize: 22, color: Colors.black54)),
                TextButton(
                  onPressed: _showTerms,
                  child: Text(
                    'Terms',
                    style: TextStyle(color: themeNotifier.value, fontSize: 16),
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            const Text(
              '© 2026 GRV TECH LABS',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'ALL RIGHTS RESERVED',
              style: TextStyle(
                color: Colors.black38,
                letterSpacing: 4,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Developed by GRV TECH LABS',
              style: TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );

  Future<void> _initRevenueCat() async {
    try {
      await Purchases.setLogLevel(LogLevel.warn);
      await initializeRevenueCat();
      _revenueCatConfigured = true;
      await _refreshPaidEntitlement();
    } catch (_) {
      // keep app functional even if RevenueCat is not configured yet
    }
  }

  Future<void> _refreshPaidEntitlement() async {
    try {
      final info = await Purchases.getCustomerInfo();
      final hasPro = _hasActivePaidEntitlement(info);
      final db = await _getDatabase();
      await db.insert(
        'settings',
        {'key': 'paid_version', 'value': hasPro.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (!mounted) return;
      setState(() => _isPaidVersion = hasPro);
    } catch (_) {
      // ignore network/SDK failures and keep local state as-is
    }
  }

  bool _hasActivePaidEntitlement(CustomerInfo info) {
    if (info.entitlements.active.containsKey(_proEntitlementId)) return true;
    return info.entitlements.active.isNotEmpty;
  }

  Future<void> _purchaseProWithRevenueCat() async {
    if (!_revenueCatConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'RevenueCat key not configured. Add Android/iOS public SDK keys.',
          ),
        ),
      );
      return;
    }
    try {
      final offerings = await Purchases.getOfferings();
      final packages = offerings.current?.availablePackages ?? [];
      final package = packages.isNotEmpty ? packages.first : null;
      if (package == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No purchasable packages found.')),
        );
        return;
      }

      await Purchases.purchasePackage(package);
      final latestInfo = await Purchases.getCustomerInfo();
      final hasPro = _hasActivePaidEntitlement(latestInfo);
      if (!mounted) return;
      setState(() => _isPaidVersion = hasPro);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasPro
                ? 'Paid features activated.'
                : 'Purchase completed. Please verify entitlement mapping in RevenueCat dashboard.',
          ),
        ),
      );
      await _refreshPaidEntitlement();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Purchase canceled or failed.')),
      );
    }
  }

  Future<void> _restoreRevenueCatPurchases() async {
    if (!_revenueCatConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'RevenueCat key not configured. Add Android/iOS public SDK keys.',
          ),
        ),
      );
      return;
    }
    try {
      await Purchases.restorePurchases();
      await _refreshPaidEntitlement();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Purchases restored.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restore failed. Try again.')),
      );
    }
  }

  Future<void> _togglePaidVersionForDemo() async {
    // Kept for backward compatibility in old local flows; now sync from RevenueCat.
    await _refreshPaidEntitlement();
  }

  Future<void> _unlockPaidForAllProfiles() async {
    await _purchaseProWithRevenueCat();
  }

  Future<void> _redeemPromoCode(String code) async {
    if (code != _familyPromoCode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid promo code.')),
      );
      return;
    }
    if (_promoUsesLeft <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Promo code usage limit reached.')),
      );
      return;
        }
    final db = await _getDatabase();
    final next = _promoUsesLeft - 1;
    await db.insert(
      'settings',
      {'key': 'promo_uses_left', 'value': next.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _purchaseProWithRevenueCat();
    if (!mounted) return;
    setState(() => _promoUsesLeft = next);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Promo accepted.')),
    );
  }

  void _showPaidOnlyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🔐 Paid Version'),
        content: const Text(
          'This feature is available in Echo Health Paid Version. Upgrade to unlock Missed Dose Tracking, Refill Prediction, Backup/Restore, Calendar Timeline, and Family Profiles.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showUpgradePurchaseDialog();
            },
            child: const Text('Purchase'),
          ),
        ],
      ),
    );
  }

  void _showUpgradePurchaseDialog() {
    final promoCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlock Paid Features'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Purchase enables premium features for all family profiles on this device.',
              ),
              const SizedBox(height: 12),
              const SizedBox(height: 4),
              const Text(
                'Promo code redemption is managed privately by the family admin.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: promoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Family promo code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    await _redeemPromoCode(promoCtrl.text.trim());
                    if (!mounted) return;
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.redeem),
                  label: const Text('Redeem Private Code'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await _purchaseProWithRevenueCat();
              if (!mounted) return;
              Navigator.pop(context);
            },
            child: const Text('Purchase'),
          ),
          TextButton(
            onPressed: () async {
              await _restoreRevenueCatPurchases();
              if (!mounted) return;
              Navigator.pop(context);
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _showMissedDoseSummary() {
    final missed = _calculateMissedDosesToday();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Missed Dose Tracking'),
        content: Text(
          missed == 0
              ? 'Great! No missed doses detected so far today.'
              : 'You have approximately $missed missed dose(s) today. Please review your schedule.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  void _showRefillPredictions() {
    final alerts = _refillPredictions();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Refill Prediction'),
        content: alerts.isEmpty
            ? const Text('No urgent refill needs. You are all set!')
            : SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: alerts
                      .map(
                        (a) => ListTile(
                          leading: const Icon(Icons.warning_amber, color: Colors.orange),
                          title: Text(a['name'].toString()),
                          subtitle: Text(
                            'Only ${a['stock']} left (~${a['daysLeft']} day(s) remaining)',
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showBackupRestoreSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Create Backup JSON'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _backupToShareJson();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Restore from JSON'),
                  onTap: () {
                    Navigator.pop(context);
                    _restoreFromJsonDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _backupToShareJson() async {
    final db = await _getDatabase();
    final backup = {
      'profiles': await db.query('profiles'),
      'meds': await db.query('meds'),
      'appts': await db.query('appts'),
      'history': await db.query('history'),
      'exportedAt': DateTime.now().toIso8601String(),
    };
    Share.share(jsonEncode(backup));
  }

  void _restoreFromJsonDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Backup'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Paste backup JSON here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              try {
                final decoded = jsonDecode(controller.text) as Map<String, dynamic>;
                final db = await _getDatabase();
                await db.transaction((txn) async {
                  await txn.delete('profiles');
                  await txn.delete('meds');
                  await txn.delete('appts');
                  await txn.delete('history');
                  for (final row in (decoded['profiles'] as List<dynamic>)) {
                    await txn.insert('profiles', Map<String, dynamic>.from(row));
                  }
                  for (final row in (decoded['meds'] as List<dynamic>)) {
                    await txn.insert('meds', Map<String, dynamic>.from(row));
                  }
                  for (final row in (decoded['appts'] as List<dynamic>)) {
                    await txn.insert('appts', Map<String, dynamic>.from(row));
                  }
                  for (final row in (decoded['history'] as List<dynamic>)) {
                    await txn.insert('history', Map<String, dynamic>.from(row));
                  }
                });
                if (!mounted) return;
                Navigator.pop(context);
                await _loadProfilesAndSettings();
                await _refreshData();
              } catch (_) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid backup JSON format.')),
                );
              }
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _showCalendarTimeline() {
    final dateCtrl = ValueNotifier<DateTime>(DateTime.now());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calendar Timeline'),
        content: SizedBox(
          width: double.maxFinite,
          child: ValueListenableBuilder<DateTime>(
            valueListenable: dateCtrl,
            builder: (context, date, _) {
              final key = DateFormat('dd MMM').format(date);
              final filtered = _history
                  .where((h) => (h['dateTaken'] ?? '').toString().contains(key))
                  .toList();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.calendar_month),
                    label: Text(DateFormat('dd MMM yyyy').format(date)),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) dateCtrl.value = picked;
                    },
                  ),
                  const Divider(),
                  if (filtered.isEmpty)
                    const Text('No timeline entries for selected date.')
                  else
                    ...filtered.map(
                      (e) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.check_circle, color: Colors.green),
                        title: Text(e['medName'].toString()),
                        subtitle: Text(e['dateTaken'].toString()),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showFamilyProfileManager() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Family Profiles'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._profiles.map(
                (p) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.person),
                  title: Text(p['name'].toString()),
                  trailing: (_activeProfileId == p['id'])
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                ),
              ),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: 'New profile name'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final db = await _getDatabase();
              await db.insert(
                'profiles',
                {'name': name, 'color': Colors.teal.value},
              );
              if (!mounted) return;
              Navigator.pop(context);
              await _loadProfilesAndSettings();
              await _refreshData();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showApptForm() {
    final docCtrl = TextEditingController();
    DateTime? selectedDate;
    TimeOfDay? selectedTime;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Schedule Doctor Visit',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              TextField(
                controller: docCtrl,
                decoration: const InputDecoration(labelText: 'Doctor/Clinic Name'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (d != null) setS(() => selectedDate = d);
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      selectedDate == null
                          ? 'Select Date'
                          : DateFormat('dd MMM yyyy').format(selectedDate!),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.now(),
                      );
                      if (t != null) setS(() => selectedTime = t);
                    },
                    icon: const Icon(Icons.access_time),
                    label: Text(
                      selectedTime == null
                          ? 'Select Time'
                          : selectedTime!.format(context),
                    ),
                  ),
                ],
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  if (docCtrl.text.isEmpty ||
                      selectedDate == null ||
                      selectedTime == null) {
                    return;
                  }
                  final db = await _getDatabase();
                  await db.insert('appts', {
                    'profileId': _activeProfileId ?? 1,
                    'docName': docCtrl.text,
                    'date': DateFormat('dd MMM yyyy').format(selectedDate!),
                    'time': selectedTime!.format(context),
                  });
                  _refreshData();
                  if (mounted) Navigator.pop(context);
                },
                child: const Text('Save Appointment'),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  List<TimeOfDay> _parseExistingTimes(String? alarmTimes) {
    if (alarmTimes == null || alarmTimes.trim().isEmpty) return [];
    final result = <TimeOfDay>[];
    for (final part in alarmTimes.split(',')) {
      final raw = part.trim();
      if (raw.isEmpty) continue;
      final normalized = raw
          .replaceAll('.', '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .toUpperCase();

      DateTime? parsed;
      final formats = [
        DateFormat('h:mm a'),
        DateFormat('hh:mm a'),
        DateFormat('H:mm'),
        DateFormat('HH:mm'),
      ];

      for (final f in formats) {
        try {
          parsed = f.parseStrict(normalized);
          break;
        } catch (_) {
          // try next format
        }
      }

      if (parsed != null) {
        result.add(TimeOfDay(hour: parsed.hour, minute: parsed.minute));
      }
    }
    return result;
  }

  String _extractMedicineName(RecognizedText res) {
    final candidates = <String>[];
    for (final block in res.blocks) {
      for (final line in block.lines) {
        final clean = line.text.replaceAll(RegExp(r'[^A-Za-z ]'), ' ').trim();
        if (clean.isNotEmpty && clean.length > 2) {
          candidates.add(clean);
        }
      }
    }
    if (candidates.isEmpty) return '';
    candidates.sort((a, b) => b.length.compareTo(a.length));
    final selected = candidates.first.split(' ').first;
    return toBeginningOfSentenceCase(selected.toLowerCase()) ?? selected;
  }

  String _serializeTimes(List<TimeOfDay> times) {
    return times
        .map(
          (t) =>
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        )
        .join(', ');
  }

  String _displayAlarmTimes(String? stored) {
    final times = _parseExistingTimes(stored);
    if (times.isEmpty) return stored ?? '';
    return times.map((t) => t.format(context)).join(', ');
  }

  Future<void> _pickMedicineImageAndScan({
    required void Function(String imagePath, String scannedName) onFound,
  }) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final img = await _picker.pickImage(source: source, imageQuality: 90);
    if (img == null) return;

    final res = await _textRecognizer.processImage(
      InputImage.fromFilePath(img.path),
    );
    final scannedName = _extractMedicineName(res);
    onFound(img.path, scannedName);
  }

  void _showMedForm({Map<String, dynamic>? existingMed}) {
    final nameCtrl = TextEditingController(text: existingMed?['name'] ?? '');
    final stockCtrl = TextEditingController(
      text: (existingMed?['stockQuantity'] ?? 30).toString(),
    );
    List<TimeOfDay> selectedTimes =
        _parseExistingTimes(existingMed?['alarmTimes'] as String?);
    String? path = existingMed?['imagePath'] as String?;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setM) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () async {
                  await _pickMedicineImageAndScan(
                    onFound: (imagePath, scannedName) {
                      setM(() {
                        path = imagePath;
                        if (scannedName.isNotEmpty) {
                          nameCtrl.text = scannedName;
                        }
                      });
                      if (scannedName.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not detect tablet name clearly. Try better lighting or gallery image.',
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
                child: Container(
                  height: 80,
                  width: double.infinity,
                  color: Colors.grey[200],
                  child: path == null
                      ? const Icon(Icons.camera_alt)
                      : Image.file(File(path!)),
                ),
              ),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Medicine Name'),
              ),
              TextField(
                controller: stockCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Initial Stock'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.now(),
                  );
                  if (t != null) setM(() => selectedTimes.add(t));
                },
                child: const Text('Add Reminder Time'),
              ),
              Wrap(
                children: selectedTimes
                    .map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                          label: Text(t.format(context)),
                          onDeleted: () => setM(() => selectedTimes.remove(t)),
                        ),
                      ),
                    )
                    .toList(),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final stock = int.tryParse(stockCtrl.text.trim());
                  if (name.isEmpty ||
                      stock == null ||
                      stock < 0 ||
                      selectedTimes.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Enter valid medicine name, stock count, and at least one reminder time.',
                        ),
                      ),
                    );
                    return;
                  }

                  final db = await _getDatabase();
                  final String tStr = _serializeTimes(selectedTimes);

                  int mid;
                  if (existingMed != null) {
                    mid = existingMed['id'] as int;
                    await NotificationService.cancelAllForMed(mid);
                    await db.update(
                      'meds',
                      {
                        'profileId': _activeProfileId ?? 1,
                        'name': name,
                        'alarmTimes': tStr,
                        'imagePath': path,
                        'stockQuantity': stock,
                      },
                      where: 'id = ?',
                      whereArgs: [mid],
                    );
                  } else {
                    mid = await db.insert('meds', {
                      'profileId': _activeProfileId ?? 1,
                      'name': name,
                      'alarmTimes': tStr,
                      'lastTaken': 'Pending',
                      'imagePath': path,
                      'stockQuantity': stock,
                    });
                  }

                  for (int i = 0; i < selectedTimes.length; i++) {
                    final profileName = _activeProfileName();
                    final DateTime sched = DateTime(
                      DateTime.now().year,
                      DateTime.now().month,
                      DateTime.now().day,
                      selectedTimes[i].hour,
                      selectedTimes[i].minute,
                    );
                    NotificationService.scheduleNotification(
                      id: (mid * 100) + i,
                      title: 'Reminder for $profileName: $name',
                      body: '$profileName needs to take medicine now',
                      scheduledDate: sched,
                      payload:
                          '$mid|$name|${_activeProfileId ?? 1}|$profileName',
                      imagePath: path,
                    );
                  }
                  _refreshData();
                  if (mounted) Navigator.pop(context);
                },
                child: Text(existingMed == null ? 'Save Pill' : 'Update Pill'),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportAllData() async {
    final db = await _getDatabase();
    final profiles = await db.query('profiles', orderBy: 'id ASC');
    final meds = await db.query('meds', orderBy: 'profileId ASC, name ASC');

    String data = 'Echo Health Stock Report\n';
    data += 'Generated: ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now())}\n\n';
    for (final profile in profiles) {
      final pid = profile['id'];
      final name = profile['name']?.toString() ?? 'Member';
      data += '👤 $name\n';
      final rows = meds.where((m) => m['profileId'] == pid).toList();
      if (rows.isEmpty) {
        data += '  - No medicines added\n\n';
        continue;
      }
      for (final m in rows) {
        data +=
            '  - ${m['name']} | Stock: ${m['stockQuantity']} | Reminders: ${m['alarmTimes']}\n';
      }
      data += '\n';
    }
    Share.share(data);
  }

  void _deleteMed(int id) async {
    final db = await _getDatabase();
    await NotificationService.cancelAllForMed(id);
    await db.delete('meds', where: 'id = ?', whereArgs: [id]);
    _refreshData();
  }

  void _showAdherenceReport() {
    final int totalMeds = _medicines.length;
    final int takenCount = _history.length;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Health Adherence Report'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.medication, color: Colors.teal),
              title: const Text('Active Medications'),
              trailing: Text('$totalMeds'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Total Doses Taken'),
              trailing: Text('$takenCount'),
            ),
            const Divider(),
            const Text(
              'Tip: Consistent medication leads to better recovery.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPermissionDashboard() async {
    await [
      Permission.notification,
      Permission.scheduleExactAlarm,
      Permission.camera,
    ].request();
    _refreshData();
  }

  void _showPrivacy() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🔒 Privacy Policy'),
        content: const Text(
          'All medication data and images are stored locally on your device. We do not collect or upload health data to servers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showTerms() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('📄 Terms of Service'),
        content: const Text(
          "This app is provided 'as-is'. The user is responsible for ensuring notifications are active and battery optimization is disabled.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'I AGREE',
              style: TextStyle(color: themeNotifier.value),
            ),
          ),
        ],
      ),
    );
  }
}
