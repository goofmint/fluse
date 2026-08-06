import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fluse counter_app',
      theme: ThemeData(
        // TRY THIS: seedColor を変えて保存すると、Hot Reload で色だけが
        // 差し替わりカウンタの値は保持される。反映経路の確認に使う。
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'fluse counter_app'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  /// `path_provider` の呼び出し結果。プラグイン解決経路が生きていれば
  /// パスが、失敗すればエラー文字列が入る。
  String _documentsPath = '取得中…';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDocumentsPath());
  }

  Future<void> _loadDocumentsPath() async {
    String result;
    try {
      final directory = await getApplicationDocumentsDirectory();
      result = directory.path;
    } on Exception catch (error) {
      // プラグインが解決されていない場合は MissingPluginException が飛ぶ。
      // 握りつぶさず画面に出すことで、検証時に原因が分かるようにする。
      result = 'path_provider の呼び出しに失敗: $error';
    }
    if (!mounted) {
      return;
    }
    setState(() => _documentsPath = result);
  }

  void _incrementCounter() {
    setState(() => _counter++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: .center,
          children: [
            // 画像 asset。差し替えて Hot Reload したときに反映されるかを見る。
            Image.asset('assets/images/fluse_logo.png', width: 96, height: 96),
            const SizedBox(height: 24),
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            // フォント asset。Inconsolata が読めていれば等幅で表示される。
            const Text(
              'Inconsolata 0O 1lI',
              style: TextStyle(fontFamily: 'Inconsolata', fontSize: 20),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _documentsPath,
                textAlign: .center,
                style: const TextStyle(fontFamily: 'Inconsolata', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
