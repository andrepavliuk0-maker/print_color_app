import 'package:flutter/material.dart';

void main() {
  runApp(const PrintColorApp());
}

class PrintColorApp extends StatelessWidget {
  const PrintColorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Print Color App',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Print Color App'),
        ),
        body: const Center(
          child: Text(
            'CMYK Color Correction',
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}
