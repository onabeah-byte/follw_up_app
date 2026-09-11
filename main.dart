// FollowUp Pro — نسخة محسّنة (ملف واحد جاهز للصق)
//
// ملحوظة: لازم تضيف الحزم دي في pubspec.yaml قبل التشغيل:
//   provider, shared_preferences, url_launcher, flutter_local_notifications,
//   timezone, csv, share_plus, path_provider
//
// وبالنسبة للتنبيهات المحلية (flutter_local_notifications) محتاج تضيف
// صلاحيات في AndroidManifest.xml — التفاصيل في آخر رسالة شرح سابقة.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

// ==================== models/customer_status.dart ====================

enum CustomerStatus {
  newLead('عميل جديد', Colors.blue),
  contacted('تم التواصل', Colors.orange),
  interested('مهتم', Colors.purple),
  closed('تم البيع', Colors.green),
  postponed('مؤجل', Colors.amber),
  cancelled('ملغي', Colors.red);

  final String label;
  final Color color;
  const CustomerStatus(this.label, this.color);
}

// ==================== models/follow_up_note.dart ====================
class FollowUpNote {
  final String text;
  final DateTime date;

  FollowUpNote({required this.text, required this.date});

  Map<String, dynamic> toJson() => {
    'text': text,
    'date': date.toIso8601String(),
  };

  factory FollowUpNote.fromJson(Map<String, dynamic> json) =>
      FollowUpNote(text: json['text'], date: DateTime.parse(json['date']));
}

// ==================== models/customer.dart ====================

class Customer {
  final String id;
  String name;
  String phone;
  String details;
  CustomerStatus status;
  DateTime nextFollowUp;
  List<FollowUpNote> notes;

  /// معرّف إشعار المتابعة المجدول لهذا العميل (لو موجود)
  /// بيتحسب من hashCode بتاع الـ id عشان يفضل ثابت لنفس العميل
  int get notificationId => id.hashCode & 0x7fffffff;

  Customer({
    required this.id,
    required this.name,
    required this.phone,
    required this.details,
    required this.status,
    required this.nextFollowUp,
    required this.notes,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'details': details,
    'status': status.name,
    'nextFollowUp': nextFollowUp.toIso8601String(),
    'notes': notes.map((n) => n.toJson()).toList(),
  };

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
    id: json['id'],
    name: json['name'],
    phone: json['phone'],
    details: json['details'],
    status: CustomerStatus.values.firstWhere(
      (e) => e.name == json['status'],
      orElse: () => CustomerStatus.newLead,
    ),
    nextFollowUp: DateTime.parse(json['nextFollowUp']),
    notes: (json['notes'] as List)
        .map((n) => FollowUpNote.fromJson(n))
        .toList(),
  );

  Customer copyWith({
    String? name,
    String? phone,
    String? details,
    CustomerStatus? status,
    DateTime? nextFollowUp,
  }) {
    return Customer(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      details: details ?? this.details,
      status: status ?? this.status,
      nextFollowUp: nextFollowUp ?? this.nextFollowUp,
      notes: notes,
    );
  }
}

// ==================== utils/phone_formatter.dart ====================
class PhoneFormatter {
  /// يحوّل أي رقم هاتف (محلي أو دولي) لصيغة دولية بدون + أو رموز
  /// عشان يتقبل في رابط wa.me
  static String formatForWhatsApp(String phone) {
    var digits = phone.replaceAll(RegExp(r'\D'), '');

    if (digits.isEmpty) return digits;

    // 0020xxxxxxxxx (بادئة صفرين دوليين + كود دولة)
    if (digits.startsWith('00')) {
      return digits.substring(2);
    }

    // رقم مصري محلي (01xxxxxxxxx - 11 رقم)
    if (digits.startsWith('0') && digits.length == 11) {
      return '20${digits.substring(1)}';
    }

    // رقم معاه كود دولة أصلاً (أطول من 10 أرقام)
    if (digits.length > 10) {
      return digits;
    }

    // حالة افتراضية: افتراض إنه مصري
    if (digits.startsWith('0')) {
      return '20${digits.substring(1)}';
    }

    return digits;
  }

  /// تحقق مبسط من صلاحية رقم الهاتف (8 أرقام على الأقل بعد التنظيف)
  static bool isValid(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 8;
  }
}

// ==================== utils/notification_service.dart ====================

/// خدمة مسؤولة عن جدولة وإلغاء تنبيهات موعد المتابعة لكل عميل.
///
/// ملاحظة مهمة: المنطقة الزمنية الافتراضية هنا "Africa/Cairo".
/// لو التطبيق هيُستخدم في دولة تانية، غيّر القيمة في `_defaultTimeZone`،
/// أو أضف مكتبة `flutter_native_timezone` لاكتشاف منطقة الجهاز تلقائيًا.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _defaultTimeZone = 'Africa/Cairo';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(_defaultTimeZone));
    } catch (_) {
      // لو المنطقة الزمنية مش موجودة في قاعدة البيانات لأي سبب، استخدم UTC
      tz.setLocalLocation(tz.UTC);
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  Future<void> requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// يجدول تنبيه في نفس موعد المتابعة (نهاية الوقت المحدد لليوم لو الوقت
  /// مش محدد بدقة). لو الموعد في الماضي، مبيتجدولش أي تنبيه.
  Future<void> scheduleFollowUpReminder({
    required int notificationId,
    required String customerName,
    required DateTime followUpDate,
  }) async {
    if (!_initialized) await init();

    final scheduledDate = tz.TZDateTime.from(followUpDate, tz.local);
    final now = tz.TZDateTime.now(tz.local);
    if (scheduledDate.isBefore(now)) return;

    const androidDetails = AndroidNotificationDetails(
      'follow_up_channel',
      'تذكير المتابعة',
      channelDescription: 'تنبيهات مواعيد متابعة العملاء',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.zonedSchedule(
      notificationId,
      'موعد متابعة عميل',
      'حان وقت متابعة العميل: $customerName',
      scheduledDate,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> cancelReminder(int notificationId) async {
    await _plugin.cancel(notificationId);
  }
}

// ==================== utils/csv_export_service.dart ====================

class CsvExportService {
  /// يبني ملف CSV من قائمة العملاء ويفتح شاشة المشاركة الخاصة بالنظام
  static Future<void> exportAndShare(List<Customer> customers) async {
    final rows = <List<dynamic>>[
      [
        'الاسم',
        'الهاتف',
        'الحالة',
        'التفاصيل',
        'موعد المتابعة القادم',
        'عدد الملاحظات',
      ],
      ...customers.map(
        (c) => [
          c.name,
          c.phone,
          c.status.label,
          c.details,
          _formatDate(c.nextFollowUp),
          c.notes.length,
        ],
      ),
    ];

    final csvData = const ListToCsvConverter().convert(rows);

    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/customers_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    // إضافة BOM عشان الإكسل يعرض العربي صح
    await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...csvData.codeUnits]);

    await Share.shareXFiles([
      XFile(file.path),
    ], text: 'بيانات العملاء - تصدير من FollowUp Pro');
  }

  static String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

// ==================== providers/settings_provider.dart ====================

class SettingsProvider extends ChangeNotifier {
  static const _kDarkMode = 'settings_dark_mode';
  static const _kCompanyName = 'settings_company_name';

  ThemeMode _themeMode = ThemeMode.light;
  String _companyName = '';
  bool _isLoaded = false;

  ThemeMode get themeMode => _themeMode;
  String get companyName => _companyName;
  bool get isLoaded => _isLoaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_kDarkMode) ?? false;
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    _companyName = prefs.getString(_kCompanyName) ?? '';
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setDarkMode(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDarkMode, isDark);
  }

  Future<void> setCompanyName(String name) async {
    _companyName = name;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCompanyName, name);
  }
}

// ==================== providers/customer_provider.dart ====================

enum SortOption {
  followUpDateAsc('الأقرب متابعة'),
  followUpDateDesc('الأبعد متابعة'),
  nameAsc('الاسم (أ-ي)'),
  recentlyAdded('الأحدث إضافة');

  final String label;
  const SortOption(this.label);
}

class CustomerProvider extends ChangeNotifier {
  static const _kStorageKey = 'customers_data';

  List<Customer> _customers = [];
  bool _isLoading = true;
  SortOption _sortOption = SortOption.followUpDateAsc;

  // للتراجع عن الحذف
  Customer? _lastDeleted;
  int? _lastDeletedIndex;

  List<Customer> get customers => _customers;
  bool get isLoading => _isLoading;
  SortOption get sortOption => _sortOption;
  bool get canUndoDelete => _lastDeleted != null;

  Future<void> load() async {
    _isLoading = true;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_kStorageKey);
    if (data != null) {
      final List decoded = jsonDecode(data);
      _customers = decoded.map((e) => Customer.fromJson(e)).toList();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(_customers.map((c) => c.toJson()).toList());
    await prefs.setString(_kStorageKey, data);
  }

  void setSortOption(SortOption option) {
    _sortOption = option;
    notifyListeners();
  }

  /// يرجع القايمة بعد الفلترة بالبحث والحالة، والترتيب المختار
  List<Customer> filteredAndSorted({
    required String query,
    CustomerStatus? statusFilter,
  }) {
    var result = _customers.where((c) {
      final matchesSearch = c.name.contains(query) || c.phone.contains(query);
      final matchesStatus = statusFilter == null || c.status == statusFilter;
      return matchesSearch && matchesStatus;
    }).toList();

    switch (_sortOption) {
      case SortOption.followUpDateAsc:
        result.sort((a, b) => a.nextFollowUp.compareTo(b.nextFollowUp));
        break;
      case SortOption.followUpDateDesc:
        result.sort((a, b) => b.nextFollowUp.compareTo(a.nextFollowUp));
        break;
      case SortOption.nameAsc:
        result.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortOption.recentlyAdded:
        result = result.reversed.toList();
        break;
    }
    return result;
  }

  Future<void> addCustomer(Customer customer) async {
    _customers.add(customer);
    notifyListeners();
    await _save();
    await NotificationService.instance.scheduleFollowUpReminder(
      notificationId: customer.notificationId,
      customerName: customer.name,
      followUpDate: customer.nextFollowUp,
    );
  }

  Future<void> updateCustomer(
    Customer customer, {
    required String name,
    required String phone,
    required String details,
    required CustomerStatus status,
    required DateTime nextFollowUp,
  }) async {
    customer.name = name;
    customer.phone = phone;
    customer.details = details;
    customer.status = status;
    customer.nextFollowUp = nextFollowUp;
    notifyListeners();
    await _save();

    // أعد جدولة التنبيه بالموعد الجديد
    await NotificationService.instance.cancelReminder(customer.notificationId);
    await NotificationService.instance.scheduleFollowUpReminder(
      notificationId: customer.notificationId,
      customerName: customer.name,
      followUpDate: customer.nextFollowUp,
    );
  }

  Future<void> deleteCustomer(Customer customer) async {
    final index = _customers.indexOf(customer);
    if (index == -1) return;
    _lastDeleted = customer;
    _lastDeletedIndex = index;
    _customers.removeAt(index);
    notifyListeners();
    await _save();
    await NotificationService.instance.cancelReminder(customer.notificationId);
  }

  Future<void> undoDelete() async {
    if (_lastDeleted == null || _lastDeletedIndex == null) return;
    final insertIndex = _lastDeletedIndex!.clamp(0, _customers.length);
    _customers.insert(insertIndex, _lastDeleted!);
    final restored = _lastDeleted!;
    _lastDeleted = null;
    _lastDeletedIndex = null;
    notifyListeners();
    await _save();
    await NotificationService.instance.scheduleFollowUpReminder(
      notificationId: restored.notificationId,
      customerName: restored.name,
      followUpDate: restored.nextFollowUp,
    );
  }

  void clearUndoState() {
    _lastDeleted = null;
    _lastDeletedIndex = null;
  }

  Future<void> addNote(Customer customer, String text) async {
    customer.notes.add(FollowUpNote(text: text, date: DateTime.now()));
    notifyListeners();
    await _save();
  }

  // ---- إحصائيات ----

  int get totalCustomers => _customers.length;

  Map<CustomerStatus, int> get countByStatus {
    final map = <CustomerStatus, int>{
      for (final s in CustomerStatus.values) s: 0,
    };
    for (final c in _customers) {
      map[c.status] = (map[c.status] ?? 0) + 1;
    }
    return map;
  }

  /// نسبة العملاء اللي وصلوا لحالة "تم البيع" من إجمالي العملاء
  double get conversionRate {
    if (_customers.isEmpty) return 0;
    final closed = _customers
        .where((c) => c.status == CustomerStatus.closed)
        .length;
    return closed / _customers.length;
  }

  int get overdueFollowUpsCount {
    final now = DateTime.now();
    return _customers
        .where(
          (c) =>
              c.nextFollowUp.isBefore(now) &&
              c.status != CustomerStatus.closed &&
              c.status != CustomerStatus.cancelled,
        )
        .length;
  }
}

// ==================== theme/app_theme.dart ====================

class AppTheme {
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: const Color(0xFFF1F5F9),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F172A),
      brightness: Brightness.light,
      primary: const Color(0xFF1E293B),
      secondary: const Color(0xFF3B82F6),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0F172A),
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
      color: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
      ),
    ),
  );

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: const Color(0xFF0B1220),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B82F6),
      brightness: Brightness.dark,
      primary: const Color(0xFF3B82F6),
      secondary: const Color(0xFF60A5FA),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF111827),
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: Color(0xFF1F2937), width: 1),
      ),
      color: Color(0xFF111827),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF111827),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF374151)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF1F2937)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2),
      ),
    ),
  );
}

// ==================== widgets/customer_form_dialog.dart ====================

Future<void> showCustomerFormDialog(
  BuildContext context, {
  Customer? customer,
}) {
  final formKey = GlobalKey<FormState>();
  final nameCtrl = TextEditingController(text: customer?.name ?? '');
  final phoneCtrl = TextEditingController(text: customer?.phone ?? '');
  final detailsCtrl = TextEditingController(text: customer?.details ?? '');
  CustomerStatus status = customer?.status ?? CustomerStatus.newLead;
  DateTime nextFollowUp =
      customer?.nextFollowUp ?? DateTime.now().add(const Duration(days: 1));

  final provider = context.read<CustomerProvider>();

  return showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(
          customer == null ? 'إضافة عميل جديد' : 'تعديل بيانات العميل',
        ),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'اسم العميل'),
                  validator: (val) => (val == null || val.trim().isEmpty)
                      ? 'اسم العميل مطلوب'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف',
                    hintText: 'مثال: 01012345678 أو +971501234567',
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'رقم الهاتف مطلوب';
                    }
                    if (!PhoneFormatter.isValid(val)) {
                      return 'رقم الهاتف غير صالح';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: detailsCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'تفاصيل العميل / الطلب',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<CustomerStatus>(
                  value: status,
                  items: CustomerStatus.values.map((s) {
                    return DropdownMenuItem(value: s, child: Text(s.label));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => status = val);
                  },
                  decoration: const InputDecoration(labelText: 'الحالة'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('تاريخ المتابعة القادمة'),
                  subtitle: Text(
                    '${nextFollowUp.year}-${nextFollowUp.month.toString().padLeft(2, '0')}-${nextFollowUp.day.toString().padLeft(2, '0')} '
                    '${nextFollowUp.hour.toString().padLeft(2, '0')}:${nextFollowUp.minute.toString().padLeft(2, '0')}',
                  ),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final pickedDate = await showDatePicker(
                      context: context,
                      initialDate: nextFollowUp,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 30),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (pickedDate == null) return;
                    if (!context.mounted) return;
                    final pickedTime = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(nextFollowUp),
                    );
                    if (!context.mounted) return;
                    setDialogState(() {
                      nextFollowUp = DateTime(
                        pickedDate.year,
                        pickedDate.month,
                        pickedDate.day,
                        pickedTime?.hour ?? nextFollowUp.hour,
                        pickedTime?.minute ?? nextFollowUp.minute,
                      );
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!(formKey.currentState?.validate() ?? false)) return;

              if (customer == null) {
                await provider.addCustomer(
                  Customer(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: nameCtrl.text.trim(),
                    phone: phoneCtrl.text.trim(),
                    details: detailsCtrl.text.trim(),
                    status: status,
                    nextFollowUp: nextFollowUp,
                    notes: [],
                  ),
                );
              } else {
                await provider.updateCustomer(
                  customer,
                  name: nameCtrl.text.trim(),
                  phone: phoneCtrl.text.trim(),
                  details: detailsCtrl.text.trim(),
                  status: status,
                  nextFollowUp: nextFollowUp,
                );
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(customer == null ? 'إضافة' : 'حفظ التعديلات'),
          ),
        ],
      ),
    ),
  );
}

// ==================== widgets/delete_confirm_dialog.dart ====================

Future<void> showDeleteConfirmDialog(BuildContext context, Customer customer) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تأكيد الحذف'),
      content: Text('هل أنت متأكد من حذف بيانات العميل (${customer.name})؟'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () async {
            final provider = context.read<CustomerProvider>();
            final messenger = ScaffoldMessenger.of(context);
            Navigator.pop(ctx);
            await provider.deleteCustomer(customer);
            messenger.showSnackBar(
              SnackBar(
                content: Text('تم حذف العميل (${customer.name})'),
                action: SnackBarAction(
                  label: 'تراجع',
                  onPressed: () => provider.undoDelete(),
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          },
          child: const Text('حذف', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

// ==================== widgets/note_dialog.dart ====================

Future<void> showAddNoteDialog(BuildContext context, Customer customer) {
  final noteCtrl = TextEditingController();
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('إضافة ملاحظة متابعة'),
      content: TextField(
        controller: noteCtrl,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'اكتب تفاصيل المتابعة...'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () async {
            if (noteCtrl.text.trim().isEmpty) return;
            await context.read<CustomerProvider>().addNote(
              customer,
              noteCtrl.text.trim(),
            );
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
}

// ==================== widgets/ai_message_dialog.dart ====================

Future<void> showAiMessageDialog(BuildContext context, Customer customer) {
  final companyName = context.read<SettingsProvider>().companyName;
  final signature = companyName.isNotEmpty
      ? '\nمع تحيات فريق $companyName'
      : '';

  final dateStr =
      '${customer.nextFollowUp.year}-${customer.nextFollowUp.month.toString().padLeft(2, '0')}-${customer.nextFollowUp.day.toString().padLeft(2, '0')}';
  final detailsText = customer.details.isNotEmpty
      ? ' بخصوص (${customer.details})'
      : '';

  final messages = [
    'مرحباً أستاذ/ة ${customer.name}، نود تذكيركم بموعد المتابعة الخاص بكم بتاريخ $dateStr$detailsText. نحن بانتظاركم ويسعدنا خدمتكم دائماً!$signature',
    'أهلاً بك أستاذ/ة ${customer.name} ✨، نتمنى أن تكون بخير. حابين نطمئن على استفسارك$detailsText. هل لديك أي تساؤل إضافي يمكننا مساعدتك به؟$signature',
    'عزيزي/تي ${customer.name}، يسعدنا التواصل معك من جديد متابعة لطلبك$detailsText. يرجى إبلاغنا بالوقت المناسب للتواصل معك اليوم.$signature',
    'مرحباً ${customer.name} 🤝، تم تحديد موعد المتابعة القادم بتاريخ $dateStr. إذا أردت تعديل الموعد أو إضافة تفاصيل جديدة لا تتردد في مراسلتنا!$signature',
  ];

  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome, color: Colors.purple),
          SizedBox(width: 8),
          Text('رسائل المتابعة الجاهزة'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: messages.length,
          separatorBuilder: (ctx, index) => const Divider(),
          itemBuilder: (ctx, index) {
            final msg = messages[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(msg, style: const TextStyle(fontSize: 13)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'نسخ النص',
                    icon: const Icon(Icons.copy, size: 20, color: Colors.blue),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: msg));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم نسخ الرسالة بنجاح!')),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'إرسال عبر واتساب',
                    icon: const Icon(Icons.send, size: 20, color: Colors.green),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _sendWhatsAppWithMessage(
                        context,
                        customer.phone,
                        msg,
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}

Future<void> _sendWhatsAppWithMessage(
  BuildContext context,
  String phone,
  String message,
) async {
  final formatted = PhoneFormatter.formatForWhatsApp(phone);
  if (formatted.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('رقم الهاتف غير صالح')));
    return;
  }
  final encodedMessage = Uri.encodeComponent(message);
  final uri = Uri.parse('https://wa.me/$formatted?text=$encodedMessage');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ==================== widgets/customer_card.dart ====================

class CustomerCard extends StatelessWidget {
  final Customer customer;
  const CustomerCard({super.key, required this.customer});

  Future<void> _makeCall(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _sendWhatsApp(BuildContext context, String phone) async {
    final formatted = PhoneFormatter.formatForWhatsApp(phone);
    if (formatted.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('رقم الهاتف غير صالح')));
      return;
    }
    final uri = Uri.parse('https://wa.me/$formatted');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  bool get _isOverdue {
    final now = DateTime.now();
    return customer.nextFollowUp.isBefore(now);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Row(
          children: [
            Expanded(
              child: Text(
                customer.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: customer.status.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                customer.status.label,
                style: TextStyle(
                  color: customer.status.color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        subtitle: Row(
          children: [
            if (_isOverdue)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: Colors.red,
                ),
              ),
            Text(
              'المتابعة القادمة: ${_formatDate(customer.nextFollowUp)}',
              style: TextStyle(
                fontSize: 12,
                color: _isOverdue ? Colors.red : Colors.grey,
                fontWeight: _isOverdue ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (customer.details.isNotEmpty) ...[
                  Text('التفاصيل: ${customer.details}'),
                  const SizedBox(height: 8),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: 'إجراء مكالمة هاتفية',
                      icon: const Icon(Icons.phone, color: Colors.green),
                      onPressed: () => _makeCall(customer.phone),
                    ),
                    IconButton(
                      tooltip: 'مراسلة عبر واتساب',
                      icon: const Icon(Icons.message, color: Colors.teal),
                      onPressed: () => _sendWhatsApp(context, customer.phone),
                    ),
                    IconButton(
                      tooltip: 'رسائل متابعة جاهزة',
                      icon: const Icon(
                        Icons.auto_awesome,
                        color: Colors.purple,
                      ),
                      onPressed: () => showAiMessageDialog(context, customer),
                    ),
                    IconButton(
                      tooltip: 'إضافة ملاحظة متابعة',
                      icon: const Icon(Icons.add_comment, color: Colors.blue),
                      onPressed: () => showAddNoteDialog(context, customer),
                    ),
                    IconButton(
                      tooltip: 'تعديل بيانات العميل',
                      icon: const Icon(Icons.edit, color: Colors.orange),
                      onPressed: () =>
                          showCustomerFormDialog(context, customer: customer),
                    ),
                    IconButton(
                      tooltip: 'حذف العميل',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () =>
                          showDeleteConfirmDialog(context, customer),
                    ),
                  ],
                ),
                const Divider(),
                const Text(
                  'سجل المتابعات:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                if (customer.notes.isEmpty)
                  const Text(
                    'لا توجد ملاحظات سابقة',
                    style: TextStyle(color: Colors.grey),
                  )
                else
                  ...customer.notes.map(
                    (n) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '• ${n.text} (${_formatDate(n.date)})',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// ==================== screens/stats_screen.dart ====================

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<CustomerProvider>(
      builder: (context, provider, _) {
        final total = provider.totalCustomers;
        final counts = provider.countByStatus;
        final conversionPct = (provider.conversionRate * 100).toStringAsFixed(
          1,
        );
        final overdue = provider.overdueFollowUpsCount;

        return Scaffold(
          appBar: AppBar(title: const Text('الإحصائيات')),
          body: total == 0
              ? const Center(child: Text('لا توجد بيانات عملاء بعد'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            title: 'إجمالي العملاء',
                            value: '$total',
                            icon: Icons.people,
                            color: Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _StatCard(
                            title: 'نسبة التحويل',
                            value: '$conversionPct%',
                            icon: Icons.trending_up,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _StatCard(
                      title: 'متابعات متأخرة',
                      value: '$overdue',
                      icon: Icons.warning_amber_rounded,
                      color: overdue > 0 ? Colors.red : Colors.grey,
                      fullWidth: true,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'توزيع العملاء حسب الحالة',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...CustomerStatus.values.map((status) {
                      final count = counts[status] ?? 0;
                      final ratio = total == 0 ? 0.0 : count / total;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  status.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text('$count'),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: ratio,
                                minHeight: 10,
                                backgroundColor: status.color.withValues(
                                  alpha: 0.12,
                                ),
                                valueColor: AlwaysStoppedAnimation(
                                  status.color,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final bool fullWidth;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== screens/settings_screen.dart ====================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _companyCtrl;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _companyCtrl = TextEditingController(text: settings.companyName);
  }

  @override
  void dispose() {
    _companyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('الإعدادات')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                title: const Text('الوضع الليلي'),
                subtitle: const Text('تفعيل المظهر الداكن للتطبيق'),
                value: settings.themeMode == ThemeMode.dark,
                onChanged: (val) => settings.setDarkMode(val),
              ),
              const Divider(height: 32),
              const Text(
                'اسم الشركة',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'هيتضاف كتوقيع تلقائي في نهاية رسائل المتابعة الجاهزة',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _companyCtrl,
                decoration: const InputDecoration(
                  hintText: 'مثال: شركة النور للتجارة',
                ),
                onSubmitted: (val) => settings.setCompanyName(val.trim()),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton(
                  onPressed: () =>
                      settings.setCompanyName(_companyCtrl.text.trim()),
                  child: const Text('حفظ'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== screens/home_screen.dart ====================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _searchQuery = '';
  CustomerStatus? _selectedStatusFilter;
  bool _isExporting = false;

  Future<void> _exportCsv(CustomerProvider provider) async {
    if (provider.customers.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا يوجد عملاء لتصديرهم')));
      return;
    }
    setState(() => _isExporting = true);
    try {
      await CsvExportService.exportAndShare(provider.customers);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('حدث خطأ أثناء التصدير')));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CustomerProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final filteredCustomers = provider.filteredAndSorted(
          query: _searchQuery,
          statusFilter: _selectedStatusFilter,
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('متابعة العملاء - FollowUp Pro'),
            actions: [
              IconButton(
                tooltip: 'تصدير بيانات العملاء (CSV)',
                icon: _isExporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.ios_share),
                onPressed: _isExporting ? null : () => _exportCsv(provider),
              ),
              IconButton(
                tooltip: 'الإحصائيات',
                icon: const Icon(Icons.bar_chart),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StatsScreen()),
                ),
              ),
              IconButton(
                tooltip: 'الإعدادات',
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'بحث باسم العميل أو رقم الهاتف...',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                FilterChip(
                                  label: const Text('الكل'),
                                  selected: _selectedStatusFilter == null,
                                  onSelected: (_) => setState(
                                    () => _selectedStatusFilter = null,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ...CustomerStatus.values.map((s) {
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: FilterChip(
                                      label: Text(s.label),
                                      selected: _selectedStatusFilter == s,
                                      onSelected: (_) => setState(() {
                                        _selectedStatusFilter =
                                            _selectedStatusFilter == s
                                            ? null
                                            : s;
                                      }),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        ),
                        PopupMenuButton<SortOption>(
                          tooltip: 'ترتيب حسب',
                          icon: const Icon(Icons.sort),
                          initialValue: provider.sortOption,
                          onSelected: (option) =>
                              provider.setSortOption(option),
                          itemBuilder: (ctx) => SortOption.values
                              .map(
                                (o) => PopupMenuItem(
                                  value: o,
                                  child: Text(o.label),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filteredCustomers.isEmpty
                    ? _EmptyState(
                        hasAnyCustomers: provider.customers.isNotEmpty,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: filteredCustomers.length,
                        itemBuilder: (context, index) =>
                            CustomerCard(customer: filteredCustomers[index]),
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'إضافة عميل جديد',
            onPressed: () => showCustomerFormDialog(context),
            child: const Icon(Icons.person_add),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasAnyCustomers;
  const _EmptyState({required this.hasAnyCustomers});

  @override
  Widget build(BuildContext context) {
    if (hasAnyCustomers) {
      // فيه عملاء لكن الفلترة/البحث محجبتهم
      return const Center(child: Text('لا يوجد عملاء مطابقين للبحث'));
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.people_outline, size: 64, color: Colors.grey),
          const SizedBox(height: 12),
          const Text(
            'لا يوجد عملاء بعد',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => showCustomerFormDialog(context),
            icon: const Icon(Icons.person_add),
            label: const Text('أضف أول عميل'),
          ),
        ],
      ),
    );
  }
}

// ==================== main.dart ====================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const FollowUpApp());
}

class FollowUpApp extends StatelessWidget {
  const FollowUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CustomerProvider()..load()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'FollowUp Pro',
            locale: const Locale('ar', 'EG'),
            builder: (context, child) {
              return Directionality(
                textDirection: TextDirection.rtl,
                child: child!,
              );
            },
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: settings.themeMode,
            home: const _AppStartup(),
          );
        },
      ),
    );
  }
}

/// يطلب صلاحية الإشعارات أول ما التطبيق يفتح، ثم يعرض الشاشة الرئيسية
class _AppStartup extends StatefulWidget {
  const _AppStartup();

  @override
  State<_AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<_AppStartup> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.requestPermissions();
    });
  }

  @override
  Widget build(BuildContext context) => const HomeScreen();
}
