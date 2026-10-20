// TEK DOSYA - lib/main.dart olarak kaydet
// pubspec.yaml bağımlılıkları aşağıda

import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/join.dart' as p;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:uuid/uuid.dart';
import 'package:equatable/equatable.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final provider = PortfolioProvider();
  await provider.init();
  runApp(ChangeNotifierProvider(create: (_) => provider, child: const PortfolioApp()));
}

// ==================== MODELS ====================
enum AssetCategory {
  preciousMetals('Kıymetli Madenler'),
  stocks('Hisse Senetleri'),
  funds('Yatırım Fonları'),
  forex('Döviz'),
  cash('Nakit ve Diğer');
  final String displayName;
  const AssetCategory(this.displayName);
}

class Asset extends Equatable {
  final String id, name, symbol;
  final AssetCategory category;
  final double quantity, averageCost;
  final String currency;
  final double? currentPrice;
  final DateTime? lastPriceUpdate;

  const Asset({required this.id, required this.name, required this.symbol, required this.category, required this.quantity, required this.averageCost, this.currency = 'TRY', this.currentPrice, this.lastPriceUpdate});

  double get totalCost => quantity * averageCost;
  double get currentValue => (currentPrice ?? averageCost) * quantity;
  double get unrealizedPnl => currentValue - totalCost;
  double get returnPercent => totalCost > 0 ? (unrealizedPnl / totalCost) * 100 : 0;

  Asset copyWith({String? id, String? name, String? symbol, AssetCategory? category, double? quantity, double? averageCost, String? currency, double? currentPrice, DateTime? lastPriceUpdate}) =>
      Asset(id: id ?? this.id, name: name ?? this.name, symbol: symbol ?? this.symbol, category: category ?? this.category, quantity: quantity ?? this.quantity, averageCost: averageCost ?? this.averageCost, currency: currency ?? this.currency, currentPrice: currentPrice ?? this.currentPrice, lastPriceUpdate: lastPriceUpdate ?? this.lastPriceUpdate);

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'symbol': symbol, 'category': category.name, 'quantity': quantity, 'averageCost': averageCost, 'currency': currency, 'currentPrice': currentPrice, 'lastPriceUpdate': lastPriceUpdate?.toIso8601String()};
  factory Asset.fromMap(Map<String, dynamic> m) => Asset(id: m['id'], name: m['name'], symbol: m['symbol'], category: AssetCategory.values.byName(m['category']), quantity: (m['quantity'] as num).toDouble(), averageCost: (m['averageCost'] as num).toDouble(), currency: m['currency'] ?? 'TRY', currentPrice: m['currentPrice'] != null ? (m['currentPrice'] as num).toDouble() : null, lastPriceUpdate: m['lastPriceUpdate'] != null ? DateTime.parse(m['lastPriceUpdate']) : null);
  @override List<Object?> get props => [id, name, symbol, category, quantity, averageCost, currency, currentPrice];
}

enum TransactionType { buy, sell, deposit, withdraw, commission, fee }

class PortfolioTransaction extends Equatable {
  final String id;
  final String? assetId;
  final TransactionType type;
  final double quantity, price, amount;
  final String currency;
  final DateTime date;
  final String? note;
  const PortfolioTransaction({required this.id, this.assetId, required this.type, this.quantity = 0, this.price = 0, required this.amount, this.currency = 'TRY', required this.date, this.note});
  Map<String, dynamic> toMap() => {'id': id, 'assetId': assetId, 'type': type.name, 'quantity': quantity, 'price': price, 'amount': amount, 'currency': currency, 'date': date.toIso8601String(), 'note': note};
  factory PortfolioTransaction.fromMap(Map<String, dynamic> m) => PortfolioTransaction(id: m['id'], assetId: m['assetId'], type: TransactionType.values.byName(m['type']), quantity: (m['quantity'] as num?)?.toDouble() ?? 0, price: (m['price'] as num?)?.toDouble() ?? 0, amount: (m['amount'] as num).toDouble(), currency: m['currency'] ?? 'TRY', date: DateTime.parse(m['date']), note: m['note']);
  @override List<Object?> get props => [id, assetId, type, quantity, price, amount, currency, date];
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();
  Future<Database> get database async => _database ??= await _initDB('portfolio.db');
  Future<Database> _initDB(String filePath) async {
    final path = p.join(await getDatabasesPath(), filePath);
    return openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE assets (id TEXT PRIMARY KEY, name TEXT, symbol TEXT, category TEXT, quantity REAL, averageCost REAL, currency TEXT, currentPrice REAL, lastPriceUpdate TEXT)');
      await db.execute('CREATE TABLE transactions (id TEXT PRIMARY KEY, assetId TEXT, type TEXT, quantity REAL, price REAL, amount REAL, currency TEXT, date TEXT, note TEXT)');
    });
  }
  Future<void> insertAsset(Asset a) async => (await database).insert('assets', a.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  Future<List<Asset>> getAllAssets() async => (await (await database).query('assets')).map(Asset.fromMap).toList();
  Future<void> updateAsset(Asset a) async => (await database).update('assets', a.toMap(), where: 'id = ?', whereArgs: [a.id]);
  Future<void> deleteAsset(String id) async => (await database).delete('assets', where: 'id = ?', whereArgs: [id]);
  Future<void> insertTransaction(PortfolioTransaction t) async => (await database).insert('transactions', t.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  Future<List<PortfolioTransaction>> getAllTransactions() async => (await (await database).query('transactions', orderBy: 'date DESC')).map(PortfolioTransaction.fromMap).toList();
  Future<void> deleteTransaction(String id) async => (await database).delete('transactions', where: 'id = ?', whereArgs: [id]);
}

class PriceService {
  static Future<double?> getPrice(String symbol) async {
    if (symbol.length <= 6 && !symbol.contains('.')) {
      final t = await TefasService.getFundPrice(symbol);
      if (t != null) return t;
    }
    try {
      final r = await http.get(Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/$symbol?interval=1d&range=1d')).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final meta = json.decode(r.body)['chart']?['result']?[0]?['meta'];
        final price = meta?['regularMarketPrice'] ?? meta?['previousClose'];
        return price is num ? price.toDouble() : null;
      }
    } catch (_) {}
    return null;
  }
  static Future<Map<String, double>> getPrices(List<String> symbols) async {
    final m = <String, double>{};
    for (final s in symbols) { final p = await getPrice(s); if (p != null) m[s] = p; }
    return m;
  }
}

class TefasService {
  static Future<double?> getFundPrice(String code) async {
    try {
      final r = await http.post(Uri.parse('https://www.tefas.gov.tr/api/DB/BindHistoryInfo'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'fontip': 'YAT', 'fonkod': code.toUpperCase(), 'bastarih': DateTime.now().subtract(const Duration(days: 5)).toIso8601String().substring(0, 10), 'bittarih': DateTime.now().toIso8601String().substring(0, 10)})
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final list = json.decode(r.body)['data'] as List?;
        if (list != null && list.isNotEmpty) {
          final price = list.last['FIYAT'] ?? list.last['fiyat'];
          if (price is num) return price.toDouble();
        }
      }
    } catch (_) {}
    return null;
  }
}

class PortfolioCalculator {
  static double totalValue(List<Asset> assets, {double usdTry = 34.0}) => assets.fold(0, (s, a) => s + (a.currency == 'USD' ? a.currentValue * usdTry : a.currency == 'EUR' ? a.currentValue * usdTry * 1.08 : a.currentValue));
  static double totalCost(List<Asset> assets, {double usdTry = 34.0}) => assets.fold(0, (s, a) => s + (a.currency == 'USD' ? a.totalCost * usdTry : a.currency == 'EUR' ? a.totalCost * usdTry * 1.08 : a.totalCost));
  static double totalPnl(List<Asset> assets, {double usdTry = 34.0}) => totalValue(assets, usdTry: usdTry) - totalCost(assets, usdTry: usdTry);
  static double totalReturnPercent(List<Asset> assets, {double usdTry = 34.0}) { final c = totalCost(assets, usdTry: usdTry); return c > 0 ? (totalPnl(assets, usdTry: usdTry) / c) * 100 : 0; }
}

class PerformanceCalculator {
  static double? xirr(List<({DateTime date, double amount})> flows) {
    if (flows.length < 2) return null;
    double rate = 0.1;
    for (int i = 0; i < 100; i++) {
      double npv = 0, dnpv = 0;
      final start = flows.first.date;
      for (final cf in flows) {
        final y = cf.date.difference(start).inDays / 365.0;
        final d = pow(1 + rate, y);
        npv += cf.amount / d;
        dnpv -= y * cf.amount / (d * (1 + rate));
      }
      if (dnpv.abs() < 1e-10) break;
      final nr = rate - npv / dnpv;
      if ((nr - rate).abs() < 1e-7) return nr;
      rate = nr.clamp(-0.99, 10.0);
    }
    return rate;
  }
  static List<({DateTime date, double amount})> cashflowsFromTransactions(List<PortfolioTransaction> txs, double current) {
    final f = <({DateTime date, double amount})>[];
    for (final t in txs) {
      final amt = (t.type == TransactionType.buy || t.type == TransactionType.deposit) ? -t.amount : t.amount;
      f.add((date: t.date, amount: amt));
    }
    f.add((date: DateTime.now(), amount: current));
    f.sort((a, b) => a.date.compareTo(b.date));
    return f;
  }
}

class MockData {
  static List<Asset> get sampleAssets => [
    const Asset(id: '1', name: 'Gram Altın', symbol: 'GAU', category: AssetCategory.preciousMetals, quantity: 50, averageCost: 2850, currentPrice: 3120),
    const Asset(id: '2', name: 'THYAO', symbol: 'THYAO.IS', category: AssetCategory.stocks, quantity: 100, averageCost: 245, currentPrice: 278),
    const Asset(id: '3', name: 'Apple', symbol: 'AAPL', category: AssetCategory.stocks, quantity: 10, averageCost: 175, currency: 'USD', currentPrice: 225),
    const Asset(id: '4', name: 'TEB Altın Fon', symbol: 'TEBALT', category: AssetCategory.funds, quantity: 500, averageCost: 12.5, currentPrice: 14.2),
    const Asset(id: '5', name: 'USD', symbol: 'USDTRY', category: AssetCategory.forex, quantity: 2000, averageCost: 32.5, currentPrice: 34.1),
  ];
  static List<PortfolioTransaction> get sampleTransactions => [
    PortfolioTransaction(id: 't1', assetId: '1', type: TransactionType.buy, quantity: 50, price: 2850, amount: 142500, date: DateTime.now().subtract(const Duration(days: 30))),
    PortfolioTransaction(id: 't2', assetId: '2', type: TransactionType.buy, quantity: 100, price: 245, amount: 24500, date: DateTime.now().subtract(const Duration(days: 15))),
  ];
}

class PortfolioProvider extends ChangeNotifier {
  final _db = DatabaseHelper.instance;
  List<Asset> assets = [];
  List<PortfolioTransaction> transactions = [];
  bool loadingPrices = false;
  String? priceError;
  Future<void> init() async {
    assets = await _db.getAllAssets();
    transactions = await _db.getAllTransactions();
    if (assets.isEmpty) {
      for (final a in MockData.sampleAssets) await _db.insertAsset(a);
      for (final t in MockData.sampleTransactions) await _db.insertTransaction(t);
      assets = await _db.getAllAssets();
      transactions = await _db.getAllTransactions();
    }
    notifyListeners();
  }
  Future<void> refreshPrices() async {
    loadingPrices = true; priceError = null; notifyListeners();
    try {
      final prices = await PriceService.getPrices(assets.map((a) => a.symbol).toSet().toList());
      for (int i = 0; i < assets.length; i++) {
        final p = prices[assets[i].symbol];
        if (p != null) { assets[i] = assets[i].copyWith(currentPrice: p, lastPriceUpdate: DateTime.now()); await _db.updateAsset(assets[i]); }
      }
    } catch (e) { priceError = e.toString(); }
    loadingPrices = false; notifyListeners();
  }
  Future<void> addAsset(Asset a) async { await _db.insertAsset(a); assets.add(a); notifyListeners(); }
  Future<void> deleteAsset(String id) async { await _db.deleteAsset(id); assets.removeWhere((a) => a.id == id); notifyListeners(); }
  Future<void> addTransaction(PortfolioTransaction t) async {
    await _db.insertTransaction(t); transactions.insert(0, t);
    if (t.assetId != null && (t.type == TransactionType.buy || t.type == TransactionType.sell)) {
      final i = assets.indexWhere((a) => a.id == t.assetId);
      if (i >= 0) {
        var a = assets[i];
        if (t.type == TransactionType.buy) {
          final nq = a.quantity + t.quantity;
          a = a.copyWith(quantity: nq, averageCost: nq > 0 ? (a.totalCost + t.quantity * t.price) / nq : 0);
        } else { a = a.copyWith(quantity: (a.quantity - t.quantity).clamp(0, double.infinity)); }
        assets[i] = a; await _db.updateAsset(a);
      }
    }
    notifyListeners();
  }
}

class PortfolioApp extends StatelessWidget {
  const PortfolioApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Portföy Takip',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)), useMaterial3: true),
    darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20), brightness: Brightness.dark), useMaterial3: true),
    themeMode: ThemeMode.system,
    home: const MainShell(),
    debugShowCheckedModeBanner: false,
  );
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override State<MainShell> createState() => _MainShellState();
}
class _MainShellState extends State<MainShell> {
  int _i = 0;
  final _screens = const [DashboardScreen(), PortfolioScreen(), TransactionsScreen(), PerformanceScreen(), SettingsScreen()];
  @override Widget build(BuildContext context) => Scaffold(
    body: _screens[_i],
    bottomNavigationBar: NavigationBar(selectedIndex: _i, onDestinationSelected: (v) => setState(() => _i = v), destinations: const [
      NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Özet'),
      NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Portföy'),
      NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'İşlemler'),
      NavigationDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: 'Analiz'),
      NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ayarlar'),
    ]),
  );
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});
  @override Widget build(BuildContext context) {
    final p = context.watch<PortfolioProvider>();
    final fmt = NumberFormat.currency(locale: 'tr_TR', symbol: '₺');
    final v = PortfolioCalculator.totalValue(p.assets), c = PortfolioCalculator.totalCost(p.assets), pnl = v - c, ret = c > 0 ? pnl / c * 100 : 0.0;
    return Scaffold(appBar: AppBar(title: const Text('Özet'), actions: [IconButton(icon: p.loadingPrices ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh), onPressed: p.loadingPrices ? null : p.refreshPrices)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Toplam Portföy Değeri', style: TextStyle(color: Colors.grey)),
          Text(fmt.format(v), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Maliyet\n${fmt.format(c)}'),
            Text('K/Z\n${fmt.format(pnl)}', style: TextStyle(color: pnl >= 0 ? Colors.green : Colors.red)),
            Text('Getiri\n${ret.toStringAsFixed(1)}%', style: TextStyle(color: ret >= 0 ? Colors.green : Colors.red)),
          ]),
        ]))),
        const SizedBox(height: 16),
        ...p.assets.map((a) => ListTile(title: Text(a.name), subtitle: Text(a.symbol), trailing: Text(fmt.format(a.currentValue)))),
      ]));
  }
}

class PortfolioScreen extends StatelessWidget {
  const PortfolioScreen({super.key});
  @override Widget build(BuildContext context) {
    final assets = context.watch<PortfolioProvider>().assets;
    return Scaffold(appBar: AppBar(title: const Text('Portföy')),
      body: ListView(children: AssetCategory.values.map((cat) {
        final list = assets.where((a) => a.category == cat).toList();
        final total = list.fold<double>(0, (s, a) => s + a.currentValue);
        return ExpansionTile(title: Text(cat.displayName, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${list.length} varlık • ${NumberFormat.currency(locale: 'tr_TR', symbol: '₺').format(total)}'),
          children: list.isEmpty ? [const ListTile(title: Text('Henüz varlık yok'))] : list.map((a) => ListTile(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AssetDetailScreen(asset: a))),
            title: Text(a.name), subtitle: Text('${a.quantity} @ ${a.averageCost.toStringAsFixed(2)}'),
            trailing: Text('${a.returnPercent >= 0 ? '+' : ''}${a.returnPercent.toStringAsFixed(1)}%', style: TextStyle(color: a.returnPercent >= 0 ? Colors.green : Colors.red)),
          )).toList());
      }).toList()),
      floatingActionButton: FloatingActionButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddAssetScreen())), child: const Icon(Icons.add)));
  }
}

class AssetDetailScreen extends StatelessWidget {
  final Asset asset;
  const AssetDetailScreen({super.key, required this.asset});
  @override Widget build(BuildContext context) {
    final p = context.watch<PortfolioProvider>();
    final a = p.assets.firstWhere((x) => x.id == asset.id, orElse: () => asset);
    final fmt = NumberFormat.currency(locale: 'tr_TR', symbol: '₺');
    return Scaffold(appBar: AppBar(title: Text(a.name), actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async {
      if (await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Sil'), content: const Text('Emin misin?'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('İptal')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sil'))])) == true) {
        await p.deleteAsset(a.id); if (context.mounted) Navigator.pop(context);
      }
    })]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Text(a.symbol, style: const TextStyle(color: Colors.grey)),
      Text(fmt.format(a.currentValue), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      _r('Miktar', a.quantity.toStringAsFixed(4)),
      _r('Ort. Maliyet', a.averageCost.toStringAsFixed(2)),
      _r('Kâr/Zarar', fmt.format(a.unrealizedPnl), color: a.unrealizedPnl >= 0 ? Colors.green : Colors.red),
      _r('Getiri', '${a.returnPercent.toStringAsFixed(2)}%'),
    ]));
  }
  Widget _r(String l, String v, {Color? color}) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l), Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: color))]));
}

class AddAssetScreen extends StatefulWidget {
  const AddAssetScreen({super.key});
  @override State<AddAssetScreen> createState() => _AddAssetScreenState();
}
class _AddAssetScreenState extends State<AddAssetScreen> {
  final _f = GlobalKey<FormState>();
  final _n = TextEditingController(), _s = TextEditingController(), _q = TextEditingController(), _c = TextEditingController();
  AssetCategory _cat = AssetCategory.stocks;
  String _cur = 'TRY';
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Varlık Ekle')), body: Form(key: _f, child: ListView(padding: const EdgeInsets.all(16), children: [
    DropdownButtonFormField(value: _cat, decoration: const InputDecoration(labelText: 'Kategori', border: OutlineInputBorder()), items: AssetCategory.values.map((c) => DropdownMenuItem(value: c, child: Text(c.displayName))).toList(), onChanged: (v) => setState(() => _cat = v!)),
    const SizedBox(height: 12),
    TextFormField(controller: _n, decoration: const InputDecoration(labelText: 'Ad', border: OutlineInputBorder()), validator: (v) => v!.isEmpty ? 'Gerekli' : null),
    const SizedBox(height: 12),
    TextFormField(controller: _s, decoration: const InputDecoration(labelText: 'Sembol', border: OutlineInputBorder()), validator: (v) => v!.isEmpty ? 'Gerekli' : null),
    const SizedBox(height: 12),
    TextFormField(controller: _q, decoration: const InputDecoration(labelText: 'Miktar', border: OutlineInputBorder()), keyboardType: TextInputType.number, validator: (v) => double.tryParse(v!) == null ? 'Geçersiz' : null),
    const SizedBox(height: 12),
    TextFormField(controller: _c, decoration: const InputDecoration(labelText: 'Maliyet', border: OutlineInputBorder()), keyboardType: TextInputType.number, validator: (v) => double.tryParse(v!) == null ? 'Geçersiz' : null),
    const SizedBox(height: 12),
    DropdownButtonFormField(value: _cur, decoration: const InputDecoration(labelText: 'Para', border: OutlineInputBorder()), items: const ['TRY','USD','EUR'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(), onChanged: (v) => setState(() => _cur = v!)),
    const SizedBox(height: 24),
    FilledButton(onPressed: () async {
      if (!_f.currentState!.validate()) return;
      await context.read<PortfolioProvider>().addAsset(Asset(id: const Uuid().v4(), name: _n.text, symbol: _s.text.toUpperCase(), category: _cat, quantity: double.parse(_q.text), averageCost: double.parse(_c.text), currency: _cur));
      if (context.mounted) Navigator.pop(context);
    }, child: const Text('Kaydet')),
  ])));
}

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});
  @override Widget build(BuildContext context) {
    final txs = context.watch<PortfolioProvider>().transactions;
    final fmt = NumberFormat.currency(locale: 'tr_TR', symbol: '₺');
    return Scaffold(appBar: AppBar(title: const Text('İşlemler')), body: ListView.builder(itemCount: txs.length, itemBuilder: (_, i) => ListTile(title: Text(txs[i].type.name.toUpperCase()), subtitle: Text(DateFormat('dd.MM.yyyy').format(txs[i].date)), trailing: Text(fmt.format(txs[i].amount)))),
      floatingActionButton: FloatingActionButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddTransactionScreen())), child: const Icon(Icons.add)));
  }
}

class AddTransactionScreen extends StatefulWidget {
  const AddTransactionScreen({super.key});
  @override State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}
class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _f = GlobalKey<FormState>();
  TransactionType _t = TransactionType.buy;
  String? _aid;
  final _q = TextEditingController(), _p = TextEditingController(), _a = TextEditingController();
  @override Widget build(BuildContext context) {
    final assets = context.watch<PortfolioProvider>().assets;
    return Scaffold(appBar: AppBar(title: const Text('İşlem Ekle')), body: Form(key: _f, child: ListView(padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField(value: _t, decoration: const InputDecoration(labelText: 'Tür', border: OutlineInputBorder()), items: TransactionType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name.toUpperCase()))).toList(), onChanged: (v) => setState(() => _t = v!)),
      const SizedBox(height: 12),
      if (_t == TransactionType.buy || _t == TransactionType.sell) DropdownButtonFormField<String>(value: _aid, decoration: const InputDecoration(labelText: 'Varlık', border: OutlineInputBorder()), items: assets.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(), onChanged: (v) => setState(() => _aid = v)),
      const SizedBox(height: 12),
      TextFormField(controller: _q, decoration: const InputDecoration(labelText: 'Miktar', border: OutlineInputBorder()), keyboardType: TextInputType.number),
      const SizedBox(height: 12),
      TextFormField(controller: _p, decoration: const InputDecoration(labelText: 'Fiyat', border: OutlineInputBorder()), keyboardType: TextInputType.number),
      const SizedBox(height: 12),
      TextFormField(controller: _a, decoration: const InputDecoration(labelText: 'Tutar', border: OutlineInputBorder()), keyboardType: TextInputType.number, validator: (v) => double.tryParse(v!) == null ? 'Geçersiz' : null),
      const SizedBox(height: 24),
      FilledButton(onPressed: () async {
        if (!_f.currentState!.validate()) return;
        await context.read<PortfolioProvider>().addTransaction(PortfolioTransaction(id: const Uuid().v4(), assetId: _aid, type: _t, quantity: double.tryParse(_q.text) ?? 0, price: double.tryParse(_p.text) ?? 0, amount: double.parse(_a.text), date: DateTime.now()));
        if (context.mounted) Navigator.pop(context);
      }, child: const Text('Kaydet')),
    ])));
  }
}

class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key});
  @override State<PerformanceScreen> createState() => _PerformanceScreenState();
}
class _PerformanceScreenState extends State<PerformanceScreen> {
  String _period = '1A';
  @override Widget build(BuildContext context) {
    final p = context.watch<PortfolioProvider>();
    final v = PortfolioCalculator.totalValue(p.assets);
    final flows = PerformanceCalculator.cashflowsFromTransactions(p.transactions, v);
    final xirr = PerformanceCalculator.xirr(flows);
    return Scaffold(appBar: AppBar(title: const Text('Analiz')), body: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: ['1G','1H','1A','3A','1Y','Tümü'].map((x) => ChoiceChip(label: Text(x), selected: _period == x, onSelected: (_) => setState(() => _period = x))).toList()),
      const SizedBox(height: 16),
      if (xirr != null) Text('XIRR: ${(xirr * 100).toStringAsFixed(2)}%', style: TextStyle(fontSize: 18, color: xirr >= 0 ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      SizedBox(height: 200, child: LineChart(LineChartData(gridData: const FlGridData(show: false), titlesData: const FlTitlesData(show: false), borderData: FlBorderData(show: false), lineBarsData: [LineChartBarData(spots: List.generate(8, (i) => FlSpot(i.toDouble(), v * (0.9 + i * 0.015))), isCurved: true, color: Colors.green, barWidth: 3, dotData: const FlDotData(show: false))]))),
    ])));
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Ayarlar')), body: ListView(children: const [
    ListTile(title: Text('Tema'), subtitle: Text('Sistem')),
    ListTile(title: Text('Veri'), subtitle: Text('Yahoo Finance + TEFAS')),
    ListTile(title: Text('Hakkında'), subtitle: Text('Portföy Takip v1.0')),
  ]));
}
