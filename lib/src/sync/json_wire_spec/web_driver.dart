// Copyright 2017 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert' show BASE64;
import 'package:stack_trace/stack_trace.dart' show Chain;

import 'by.dart' show byToJson;
import 'keyboard.dart';
import 'logs.dart';
import 'mouse.dart';
import 'navigation.dart';
import 'target_locator.dart';
import 'timeouts.dart';
import 'web_element.dart';
import 'window.dart';

import '../../../async_core.dart' as async_core;

import '../common_spec/cookies.dart';
import '../command_event.dart';
import '../command_processor.dart';
import '../common.dart';
import '../navigation.dart';
import '../target_locator.dart';
import '../timeouts.dart';
import '../web_driver.dart';
import '../web_element.dart';
import '../window.dart';

class JsonWireWebDriver implements WebDriver, SearchContext {
  final CommandProcessor _commandProcessor;
  final Uri _prefix;
  @override
  final Map<String, dynamic> capabilities;
  @override
  final String id;
  @override
  final Uri uri;
  @override
  final bool filterStackTraces;

  @override
  bool notifyListeners = true;

  final _commandListeners = <WebDriverListener>[];

  JsonWireWebDriver(
      this._commandProcessor, this.uri, this.id, this.capabilities,
      {this.filterStackTraces: true})
      : this._prefix = uri.resolve('session/$id/');

  @override
  async_core.WebDriver get asyncDriver => createAsyncWebDriver(this);

  @override
  async_core.SearchContext get asyncContext => asyncDriver;

  @override
  void addEventListener(WebDriverListener listener) =>
      _commandListeners.add(listener);

  @override
  String get currentUrl => getRequest('url') as String;

  @override
  void get(/* Uri | String */ url) {
    final urlStr = (url is Uri) ? url.toString() : url;
    postRequest('url', {'url': urlStr as String});
  }

  @override
  String get title => getRequest('title') as String;

  @override
  List<WebElement> findElements(By by) {
    final elements = postRequest('elements', byToJson(by));
    int i = 0;

    final webElements = <JsonWireWebElement>[];
    for (final element in elements) {
      webElements.add(new JsonWireWebElement(
          this, element[jsonWireElementStr], this, by, i++));
    }
    return webElements;
  }

  @override
  WebElement findElement(By by) {
    final element = postRequest('element', byToJson(by));
    return new JsonWireWebElement(this, element[jsonWireElementStr], this, by);
  }

  @override
  String get pageSource => getRequest('source') as String;

  @override
  void close() {
    deleteRequest('window');
  }

  @override
  void quit({bool closeSession: true}) {
    try {
      if (closeSession) {
        _commandProcessor.delete(uri.resolve('session/$id'));
      }
    } finally {
      _commandProcessor.close();
    }
  }

  @override
  List<Window> get windows => new JsonWireWindows(this).allWindows;

  @override
  Window get window => new JsonWireWindows(this).activeWindow;

  @override
  WebElement get activeElement {
    final element = postRequest('element/active');
    if (element != null) {
      return new JsonWireWebElement(
          this, element[jsonWireElementStr], this, 'activeElement');
    }
    return null;
  }

  @override
  Windows get windowsManager => new JsonWireWindows(this);

  @override
  TargetLocator get switchTo => new JsonWireTargetLocator(this);

  @override
  Navigation get navigate => new JsonWireNavigation(this);

  @override
  Cookies get cookies => new Cookies(this);

  @override
  Logs get logs => new Logs(this);

  @override
  Timeouts get timeouts => new JsonWireTimeouts(this);

  @override
  Keyboard get keyboard => new Keyboard(this);

  @override
  Mouse get mouse => new Mouse(this);

  @override
  String captureScreenshotAsBase64() => getRequest('screenshot');

  @override
  List<int> captureScreenshotAsList() {
    final base64Encoded = captureScreenshotAsBase64();
    return BASE64.decode(base64Encoded);
  }

  @override
  dynamic executeAsync(String script, List args) => _recursiveElementify(
      postRequest('execute_async', {'script': script, 'args': args}));

  @override
  dynamic execute(String script, List args) => _recursiveElementify(
      postRequest('execute', {'script': script, 'args': args}));

  dynamic _recursiveElementify(result) {
    if (result is Map) {
      if (result.length == 1 && result.containsKey(jsonWireElementStr)) {
        return new JsonWireWebElement(
            this, result[jsonWireElementStr], this, 'javascript');
      } else {
        final newResult = {};
        result.forEach((key, value) {
          newResult[key] = _recursiveElementify(value);
        });
        return newResult;
      }
    } else if (result is List) {
      return result.map(_recursiveElementify).toList();
    } else {
      return result;
    }
  }

  @override
  dynamic postRequest(String command, [params]) => _performRequestWithLog(
      () => _commandProcessor.post(_resolve(command), params),
      'POST',
      command,
      params);

  @override
  dynamic getRequest(String command) => _performRequestWithLog(
      () => _commandProcessor.get(_resolve(command)), 'GET', command, null);

  @override
  dynamic deleteRequest(String command) => _performRequestWithLog(
      () => _commandProcessor.delete(_resolve(command)),
      'DELETE',
      command,
      null);

  // Performs request and sends the result to listeners/onCommandController.
  // This is typically always what you want to use.
  dynamic _performRequestWithLog(
      Function fn, String method, String command, params) {
    return _performRequest(fn, method, command, params);
  }

  // Performs the request. This will not notify any listeners or
  // onCommandController. This should only be called from
  // _performRequestWithLog.
  dynamic _performRequest(Function fn, String method, String command, params) {
    final startTime = new DateTime.now();
    var trace = new Chain.current();
    if (filterStackTraces) {
      trace = trace.foldFrames(
          (f) => f.library.startsWith('package:webdriver/'),
          terse: true);
    }
    var result;
    var exception;
    try {
      result = fn();
      return result;
    } catch (e) {
      exception = e;
      rethrow;
    } finally {
      if (notifyListeners) {
        for (WebDriverListener listener in _commandListeners) {
          listener(new WebDriverCommandEvent(
              method: method,
              endPoint: command,
              params: params,
              startTime: startTime,
              endTime: new DateTime.now(),
              exception: exception,
              result: result,
              stackTrace: trace));
        }
      }
    }
  }

  Uri _resolve(String command) {
    var uri = _prefix.resolve(command);
    if (uri.path.endsWith('/')) {
      uri = uri.replace(path: uri.path.substring(0, uri.path.length - 1));
    }
    return uri;
  }

  @override
  WebDriver get driver => this;

  @override
  String toString() => 'JsonWireWebDriver($_prefix)';
}
