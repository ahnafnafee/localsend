import 'dart:io';

import 'package:args/args.dart';
import 'package:cli/src/receiver.dart';
import 'package:cli/src/tls.dart';
import 'package:common/constants.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage information');

  final receive = parser.addCommand('receive')
    ..addOption('alias', help: 'Device name shown to senders (default: this host)')
    ..addOption('port', abbr: 'p', help: 'Port to listen on', defaultsTo: '$defaultPort')
    ..addOption('dir', abbr: 'd', help: 'Directory to save received files (default: ./localsend)')
    ..addOption('pin', help: 'Require this PIN for incoming transfers')
    ..addFlag('http', help: 'Serve plain HTTP instead of HTTPS', defaultsTo: false, negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage information');

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (results.command?.name == 'receive') {
    final cmd = results.command!;
    if (cmd['help'] as bool) {
      _printReceiveUsage(receive);
      return;
    }
    await _runReceive(cmd);
    return;
  }

  _printUsage(parser);
}

Future<void> _runReceive(ArgResults cmd) async {
  _initMappers();

  final port = int.tryParse(cmd['port'] as String);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Invalid --port: ${cmd['port']}');
    exitCode = 64;
    return;
  }
  final https = !(cmd['http'] as bool);
  final dirPath = (cmd['dir'] as String?) ?? p.join(Directory.current.path, 'localsend');
  final alias = (cmd['alias'] as String?) ?? _defaultAlias();
  final pin = cmd['pin'] as String?;

  final credentials = generateTlsCredentials();
  final receiver = LocalSendReceiver(
    config: ReceiverConfig(
      alias: alias,
      port: port,
      destination: Directory(dirPath),
      https: https,
      pin: pin,
    ),
    credentials: credentials,
  );

  try {
    await receiver.start();
  } catch (e) {
    stderr.writeln('Failed to start receiver on port $port: $e');
    exitCode = 70;
    return;
  }

  await _printBanner(alias: alias, port: port, https: https, dir: Directory(dirPath).absolute.path, fingerprint: credentials.fingerprint, pin: pin);

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down…');
    await receiver.stop();
    exit(0);
  });
}

void _initMappers() {
  // dart_mappable codegen + the hand-written FileDtoMapper (see app/lib/config/init.dart).
  InfoDtoMapper.ensureInitialized();
  InfoRegisterDtoMapper.ensureInitialized();
  PrepareUploadRequestDtoMapper.ensureInitialized();
  PrepareUploadResponseDtoMapper.ensureInitialized();
  FileMetadataMapper.ensureInitialized();
  MapperContainer.globals.use(const FileDtoMapper());
}

String _defaultAlias() {
  try {
    return '${Platform.localHostname} (headless)';
  } catch (_) {
    return 'LocalSend CLI';
  }
}

Future<void> _printBanner({
  required String alias,
  required int port,
  required bool https,
  required String dir,
  required String fingerprint,
  required String? pin,
}) async {
  final scheme = https ? 'https' : 'http';
  final ips = <String>[];
  try {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final addr in ni.addresses) {
        if (!addr.isLoopback) ips.add(addr.address);
      }
    }
  } catch (_) {}

  stdout.writeln('LocalSend headless receiver');
  stdout.writeln('  Alias       : $alias');
  stdout.writeln('  Protocol    : $scheme  (port $port)');
  stdout.writeln('  Save to     : $dir');
  stdout.writeln('  Fingerprint : $fingerprint');
  stdout.writeln('  PIN         : ${pin == null ? 'none' : 'required'}');
  if (ips.isNotEmpty) {
    stdout.writeln('Reachable at:');
    for (final ip in ips) {
      stdout.writeln('  $scheme://$ip:$port');
    }
  }
  stdout.writeln('Add this device by IP as a favorite on your other devices. Press Ctrl+C to stop.');
}

void _printUsage(ArgParser parser) {
  stdout.writeln('LocalSend CLI — send and receive files locally.');
  stdout.writeln('');
  stdout.writeln('Usage: ${p.basename(Platform.executable)} <command> [options]');
  stdout.writeln('');
  stdout.writeln('Commands:');
  stdout.writeln('  receive    Run a headless receiver that auto-accepts incoming files');
  stdout.writeln('');
  stdout.writeln('Global options:');
  stdout.writeln(parser.usage);
  stdout.writeln('');
  stdout.writeln('Run "<command> --help" for command options, e.g. "receive --help".');
}

void _printReceiveUsage(ArgParser receive) {
  stdout.writeln('Run a headless LocalSend receiver (auto-accepts every transfer).');
  stdout.writeln('');
  stdout.writeln('Usage: localsend receive [options]');
  stdout.writeln('');
  stdout.writeln(receive.usage);
}
