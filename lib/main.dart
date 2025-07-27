import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';

void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late stt.SpeechToText _speech;
  late FlutterTts _tts;
  bool _isListening = false;
  String _spokenText = '';
  String _parsedJson = '';
  String _locationText = '위치 정보를 불러오는 중...';
  Position? _currentPosition;
  Stream<Position>? _positionStream;

  @override
  void initState() {
    super.initState();
    _tts = FlutterTts();
    _requestLocationPermission();
    _requestMicrophonePermission();
    _startTTSIntro();
  }

  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationText = "위치 서비스가 꺼져 있습니다.";
      });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _locationText = "위치 권한이 거부되었습니다.";
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _locationText = "위치 권한이 영구적으로 거부되었습니다.";
      });
      return;
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, 
      ),
    );

    _positionStream!.listen((Position position) {
      setState(() {
        _currentPosition = position;
        _locationText = "위도: ${position.latitude}, 경도: ${position.longitude}";
      });
    });
  }

  Future<void> _requestMicrophonePermission() async {
    var status = await Permission.microphone.request();
    if (status.isGranted) {
      _speech = stt.SpeechToText();
    } else {
      setState(() {
        _spokenText = '마이크 권한이 필요합니다.';
      });
    }
  }

  Future<void> _startTTSIntro() async {
    await Future.delayed(Duration(seconds: 5));
    await _tts.setLanguage("ko-KR");
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak("말하면 제가 듣고 안내할게요.");
    _startListening();
  }

  void _startListening() async {
    bool available = await _speech.initialize(
      onStatus: (status) {
        print("STT 상태: $status");
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
      onError: (error) => print("STT 오류: $error"),
    );

    if (available) {
      setState(() => _isListening = true);

      _speech.listen(
        onResult: (result) {
          setState(() {
            _spokenText = result.recognizedWords;
          });

          _speech.stop();
          setState(() => _isListening = false);

          _callGPT(_spokenText);
        },
        listenMode: stt.ListenMode.dictation,
        listenFor: Duration(seconds: 30),
        pauseFor: Duration(seconds: 30),
        cancelOnError: true,
      );
    } else {
      setState(() {
        _spokenText = "STT 사용 불가: 초기화 실패";
      });
    }
  }

  void _callGPT(String text) async {
    String locationString = "";
    if (_currentPosition != null) {
      locationString = "현재 위치는 위도 ${_currentPosition!.latitude}, 경도 ${_currentPosition!.longitude}입니다.";
    }

    final prompt = '''
너는 시각장애인을 위한 내비게이션 질의 파서야.
다음 문장에서 출발지, 도착지, 제약조건(예: 점자블록), 사용자유형, 요청유형을 JSON으로 출력해줘.
출발지가 없으면 '현재 위치'로 설정하고, 참고로 사용자의 실제 GPS 위치는 다음과 같아: $locationString
설명 없이 JSON만 정확히 출력해.
문장: "$text"
''';

    final response = await http.post(
      Uri.parse("https://api.openai.com/v1/chat/completions"),
      headers: {
        "Authorization": "Bearer sk-xxxxxxxxxxxx",
        "Content-Type": "application/json"
      },
      body: json.encode({
        "model": "gpt-3.5-turbo",
        "messages": [
          {"role": "system", "content": prompt},
        ],
        "temperature": 0.2,
      }),
    );

    final bodyString = utf8.decode(response.bodyBytes);
    print("GPT 응답 원문:\n$bodyString");

    if (response.statusCode == 200) {
      final data = json.decode(bodyString);
      final raw = data["choices"][0]["message"]["content"];

      try {
        final decoded = json.decode(raw);
        if (decoded is String) {
          final doubleDecoded = json.decode(decoded);
          setState(() {
            _parsedJson = const JsonEncoder.withIndent('  ').convert(doubleDecoded);
          });
        } else {
          setState(() {
            _parsedJson = const JsonEncoder.withIndent('  ').convert(decoded);
          });
        }
      } catch (e) {
        setState(() {
          _parsedJson = raw;
        });
      }
    } else {
      setState(() {
        _parsedJson = "GPT 호출 실패: ${response.statusCode}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text("시각장애인 보행 네비게이션")),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("현재 위치:\n$_locationText"),
              SizedBox(height: 10),
              ElevatedButton(
                onPressed: _isListening ? null : _startListening,
                child: Text(_isListening ? "듣는 중..." : "말하기 시작"),
              ),
              SizedBox(height: 20),
              Text("인식된 문장:\n$_spokenText"),
              Divider(),
              Text("GPT 파싱 결과:"),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    _parsedJson,
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
