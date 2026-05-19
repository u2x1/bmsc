import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/util/logger.dart';
import 'package:gt3_flutter_plugin/gt3_flutter_plugin.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:async';

final logger = LoggerUtils.getLogger('LoginScreen');

enum LoginType {
  password,
  sms,
  qrcode,
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _smsCodeController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _infoMessage;
  LoginType _loginType = LoginType.sms;
  String? _captchaKey;
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  Timer? _qrcodeTimer;
  String? _qrcodeKey;
  String? _qrcodeUrl;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _login(BuildContext context) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final captcha =
          await BilibiliService.instance.then((x) => x.getLoginCaptcha());
      if (captcha == null) {
        throw Exception('Failed to get login captcha');
      }

      logger.info('Geetest gt: ${captcha['gt']}');
      final geetest = Gt3FlutterPlugin();

      Gt3RegisterData registerData = Gt3RegisterData(
          gt: captcha['gt']!, challenge: captcha['challenge']!, success: true);

      geetest.addEventHandler(onShow: (message) {
        logger.info('Geetest challenge dialog shown: $message');
      }, onResult: (Map<String, dynamic> result) async {
        try {
          logger.info('Geetest verification result: $result');
          result = Map<String, dynamic>.from(result['result']);
          final (loginSuccess, loginError) =
              await BilibiliService.instance.then((x) => x.passwordLogin(
                    _usernameController.text,
                    _passwordController.text,
                    {
                      'token': captcha['token']!,
                      'challenge': result['geetest_challenge'],
                      'validate': result['geetest_validate'],
                      'seccode': result['geetest_seccode'],
                    },
                  ));

          if (loginSuccess) {
            await BilibiliService.instance.then((x) => x.refreshMyInfo());
            if (context.mounted) {
              Navigator.pop(context, true);
            }
          } else {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(loginError ?? '登录失败')));
          }
        } catch (e) {
          logger.severe('Geetest onResult error: $e');
          throw Exception('Geetest onResult error: $e');
        }
      }, onError: (error) {
        logger.severe('Geetest error: $error');
        throw Exception('Geetest error: $error');
      });

      geetest.startCaptcha(registerData);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
      logger.warning('Login error: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _getSmsCode(BuildContext context) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final captcha =
          await BilibiliService.instance.then((x) => x.getLoginCaptcha());
      if (captcha == null) {
        throw Exception('Failed to get login captcha');
      }

      final geetest = Gt3FlutterPlugin();
      Gt3RegisterData registerData = Gt3RegisterData(
          gt: captcha['gt']!, challenge: captcha['challenge']!, success: true);

      geetest.addEventHandler(
        onShow: (message) {
          logger.info('Geetest challenge dialog shown: $message');
        },
        onResult: (Map<String, dynamic> result) async {
          try {
            logger.info('Geetest verification result: $result');
            result = Map<String, dynamic>.from(result['result']);
            final (captchaKey, error) =
                await BilibiliService.instance.then((x) => x.getSmsLoginCaptcha(
                      int.parse(_phoneController.text),
                      {
                        'token': captcha['token']!,
                        'challenge': result['geetest_challenge'],
                        'validate': result['geetest_validate'],
                        'seccode': result['geetest_seccode'],
                      },
                    ));

            if (error != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(error)),
              );
            } else {
              _captchaKey = captchaKey;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('验证码已发送')),
              );
            }
          } catch (e) {
            logger.severe('Geetest onResult error: $e');
            throw Exception('Geetest onResult error: $e');
          }
        },
        onError: (error) {
          logger.severe('Geetest error: $error');
          throw Exception('Geetest error: $error');
        },
      );

      geetest.startCaptcha(registerData);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
      logger.warning('SMS code error: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _smsLogin(BuildContext context) async {
    if (_captchaKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先获取验证码')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final (loginSuccess, loginError) =
          await BilibiliService.instance.then((x) => x.smsLogin(
                int.parse(_phoneController.text),
                _smsCodeController.text,
                _captchaKey!,
              ));

      if (loginSuccess) {
        await BilibiliService.instance.then((x) => x.refreshMyInfo());
        if (context.mounted) {
          Navigator.pop(context, true);
        }
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(loginError ?? '登录失败')));
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
      logger.warning('SMS login error: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _initQrcodeLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final qrcodeInfo =
          await BilibiliService.instance.then((x) => x.getQrcodeLoginInfo());
      if (qrcodeInfo == null) {
        throw Exception('Failed to get QR code');
      }

      setState(() {
        _qrcodeUrl = qrcodeInfo.$1;
        _qrcodeKey = qrcodeInfo.$2;
      });

      _qrcodeTimer?.cancel();
      _qrcodeTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (_qrcodeKey == null) {
          timer.cancel();
          return;
        }

        final status = await BilibiliService.instance
            .then((x) => x.checkQrcodeLoginStatus(_qrcodeKey!));

        if (status == null) {
          timer.cancel();
          setState(() {
            _errorMessage = '二维码已过期，请重新获取';
            _qrcodeUrl = null;
            _qrcodeKey = null;
          });
          return;
        }

        switch (status) {
          case 0:
            timer.cancel();
            await BilibiliService.instance.then((x) => x.refreshMyInfo());
            if (mounted) {
              Navigator.pop(context, true);
            }
            break;
          case 86090:
            setState(() {
              _infoMessage = '已扫码，请在手机端确认';
            });
            break;
          case 86038:
            timer.cancel();
            setState(() {
              _errorMessage = '二维码已过期，请重新获取';
              _qrcodeUrl = null;
              _qrcodeKey = null;
            });
            break;
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
      logger.warning('QR code login error: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录', style: TextStyle(fontWeight: FontWeight.w600)),
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _loginType = LoginType.qrcode;
                _errorMessage = null;
              });
            },
            icon: Icon(Icons.qr_code_scanner),
            label: Text('二维码'),
          ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (_loginType == LoginType.sms) {
                  _loginType = LoginType.password;
                } else {
                  _loginType = LoginType.sms;
                }
                _errorMessage = null;
              });
            },
            icon: Icon(_loginType == LoginType.sms
                ? Icons.lock_outline
                : Icons.message_outlined),
            label: Text(_loginType == LoginType.sms ? '密码':  '短信'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/icon.png',
                    width: 100,
                    height: 100,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _loginType == LoginType.password
                      ? '账号密码登录'
                      : _loginType == LoginType.sms
                          ? '手机验证码登录'
                          : '二维码登录',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (_loginType == LoginType.password) ...[
                  TextFormField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: '账号',
                      hintText: '请输入手机号或邮箱',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    enabled: !_isLoading,
                    validator: (value) {
                      if (value?.isEmpty ?? true) return '请输入账号';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: '密码',
                      hintText: '请输入密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    obscureText: _obscurePassword,
                    enabled: !_isLoading,
                    validator: (value) {
                      if (value?.isEmpty ?? true) return '请输入密码';
                      return null;
                    },
                  ),
                ] else if (_loginType == LoginType.sms) ...[
                  TextFormField(
                    controller: _phoneController,
                    decoration: InputDecoration(
                      labelText: '手机号',
                      hintText: '请输入手机号',
                      prefixIcon: const Icon(Icons.phone_android),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    keyboardType: TextInputType.phone,
                    enabled: !_isLoading,
                    validator: (value) {
                      if (value?.isEmpty ?? true) return '请输入手机号';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _smsCodeController,
                          decoration: InputDecoration(
                            labelText: '验证码',
                            hintText: '请输入验证码',
                            prefixIcon: const Icon(Icons.security),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          keyboardType: TextInputType.number,
                          enabled: !_isLoading,
                          validator: (value) {
                            if (value?.isEmpty ?? true) return '请输入验证码';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed:
                            _isLoading ? null : () => _getSmsCode(context),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('获取'),
                      ),
                    ],
                  ),
                ] else ...[
                  if (_qrcodeUrl != null)
                    Center(
                      child: Column(
                        children: [
                          QrImageView(
                            backgroundColor: Colors.white,
                            data: _qrcodeUrl!,
                            version: QrVersions.auto,
                            size: 200.0,
                          ),
                          const SizedBox(height: 16),
                          const Text('请使用哔哩哔哩手机客户端扫描二维码登录'),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _initQrcodeLogin,
                            child: const Text('刷新二维码'),
                          ),
                        ],
                      ),
                    )
                  else
                    Center(
                      child: _isLoading
                          ? const CircularProgressIndicator()
                          : ElevatedButton(
                              onPressed: _initQrcodeLogin,
                              child: const Text('获取二维码'),
                            ),
                    ),
                ],
                if (_infoMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _infoMessage!,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                if (_loginType != LoginType.qrcode)
                  FilledButton(
                    onPressed: _isLoading
                        ? null
                        : () {
                            if (_formKey.currentState?.validate() ?? false) {
                              _loginType == LoginType.sms
                                  ? _smsLogin(context)
                                  : _loginType == LoginType.password
                                      ? _login(context)
                                      : null;
                            }
                          },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            '登录',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _smsCodeController.dispose();
    _qrcodeTimer?.cancel();
    super.dispose();
  }
}
