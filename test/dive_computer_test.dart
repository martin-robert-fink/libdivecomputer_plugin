import 'package:flutter_test/flutter_test.dart';
import 'package:dive_computer/dive_computer.dart';
import 'package:dive_computer/dive_computer_platform_interface.dart';
import 'package:dive_computer/dive_computer_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockDiveComputerPlatform
    with MockPlatformInterfaceMixin
    implements DiveComputerPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final DiveComputerPlatform initialPlatform = DiveComputerPlatform.instance;

  test('$MethodChannelDiveComputer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelDiveComputer>());
  });

  test('getPlatformVersion', () async {
    DiveComputer diveComputerPlugin = DiveComputer();
    MockDiveComputerPlatform fakePlatform = MockDiveComputerPlatform();
    DiveComputerPlatform.instance = fakePlatform;

    expect(await diveComputerPlugin.getPlatformVersion(), '42');
  });
}
