import 'package:bmsc/model/login.dart';
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
  final _riskSmsCodeController = TextEditingController();
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
  String? _qrcodeAuthCode;
  bool _qrcodeIsTv = true;
  bool _qrcodePolling = false;
  bool _qrcodeFinished = false;
  Timer? _smsCountdownTimer;
  int _smsCountdown = 0;

  /// 当前极验参数（App 登录接口用）
  CaptchaData? _captchaData;

  // ===== 密码登录风控（安全中心，对齐 BiliPai） =====
  RiskVerifyParams? _riskParams;
  String _riskHideTel = '';
  SafeCenterCaptchaPre? _riskCaptchaPre;
  String _riskCaptchaKey = '';
  bool _riskSmsSent = false;

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
      _captchaData = CaptchaData(
        token: captcha['token'] ?? '',
        gt: captcha['gt'],
        challenge: captcha['challenge'],
      );
      if (_captchaData!.gt == null || _captchaData!.challenge == null) {
        throw Exception('缺少验证码参数');
      }

      logger.info('Geetest gt: ${_captchaData!.gt}');
      final geetest = Gt3FlutterPlugin();

      Gt3RegisterData registerData = Gt3RegisterData(
          gt: _captchaData!.gt!,
          challenge: _captchaData!.challenge!,
          success: true);

      geetest.addEventHandler(onShow: (message) {
        logger.info('Geetest challenge dialog shown: $message');
      }, onResult: (Map<String, dynamic> result) async {
        try {
          logger.info('Geetest verification result: $result');
          final geetestResult = result['result'];
          if (geetestResult == null) {
            setState(() {
              _errorMessage = '人机验证失败，请重试';
            });
            return;
          }
          result = Map<String, dynamic>.from(geetestResult);
          final loginResult = await BilibiliService.instance.then(
              (x) => x.passwordLoginApp(
                    _usernameController.text,
                    _passwordController.text,
                    _captchaData,
                    validate: result['geetest_validate'],
                    seccode: result['geetest_seccode'],
                    challenge: result['geetest_challenge'],
                  ));

          if (loginResult.isSuccess) {
            await BilibiliService.instance
                .then((x) => x.applyLoginSession(loginResult));
            if (context.mounted) {
              Navigator.pop(context, true);
            }
          } else if (loginResult.needRiskVerification) {
            // status=2 风控：走安全中心手机号验证
            await _beginRiskVerification(loginResult);
          } else if (loginResult.needRecaptcha) {
            // -105：URL 里带新的极验参数，重新验证
            final newCaptcha = parseLoginRecaptchaUrl(loginResult.url);
            if (newCaptcha != null) {
              _captchaData = newCaptcha;
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请重新完成人机验证')),
                );
              }
            } else {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loginResult.message.isEmpty
                      ? '登录失败，请重试'
                      : loginResult.message)),
                );
              }
            }
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loginResult.message.isEmpty
                      ? '登录失败'
                      : loginResult.message)));
            }
          }
        } catch (e) {
          logger.severe('Geetest onResult error: $e');
          if (context.mounted) {
            setState(() {
              _errorMessage = '登录失败: $e';
            });
          }
        }
      }, onError: (error) {
        logger.severe('Geetest error: $error');
        if (context.mounted) {
          setState(() {
            _errorMessage = '人机验证失败: $error';
          });
        }
      });

      geetest.startCaptcha(registerData);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
      logger.warning('Login error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ===== 风控流程（对齐 BiliPai：status=2 → 安全中心手机号验证） =====

  Future<void> _beginRiskVerification(AppLoginResult result) async {
    final params = parseRiskVerifyUrl(result.url);
    if (params == null) {
      setState(() {
        _errorMessage = '登录环境存在风险，但验证参数缺失，请改用扫码登录';
      });
      return;
    }
    _riskParams = params;
    _riskSmsSent = false;
    _riskCaptchaKey = '';
    try {
      final info = await BilibiliService.instance
          .then((x) => x.getSafeCenterInfo(params.tmpCode));
      if (info == null || !info.telVerify) {
        _riskParams = null;
        setState(() {
          _errorMessage = '当前账号不支持手机号风控验证，请改用扫码登录';
        });
        return;
      }
      _riskHideTel = info.hideTel;
      setState(() {
        _infoMessage =
            '本次登录环境存在风险，需使用绑定手机号 ${info.hideTel} 完成验证';
        _errorMessage = null;
      });
    } catch (e) {
      _riskParams = null;
      setState(() {
        _errorMessage = '安全验证准备失败: $e';
      });
    }
  }

  Future<void> _riskSendSmsCode() async {
    if (_riskParams == null) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final pre = await BilibiliService.instance
          .then((x) => x.getSafeCenterCaptchaPre());
      if (pre == null || !pre.isReady) {
        setState(() {
          _errorMessage = '获取风控验证码失败，请改用扫码登录';
        });
        return;
      }
      _riskCaptchaPre = pre;
      final geetest = Gt3FlutterPlugin();
      final registerData = Gt3RegisterData(
          gt: pre.geeGt, challenge: pre.geeChallenge, success: true);
      geetest.addEventHandler(
        onShow: (message) {
          logger.info('Geetest challenge dialog shown: $message');
        },
        onResult: (Map<String, dynamic> result) async {
          try {
            final geetestResult = result['result'];
            if (geetestResult == null) {
              setState(() {
                _errorMessage = '人机验证失败，请重试';
              });
              return;
            }
            final map = Map<String, dynamic>.from(geetestResult);
            final (captchaKey, error) = await BilibiliService.instance.then(
                (x) => x.sendSafeCenterSms(
                      tmpCode: _riskParams!.tmpCode,
                      recaptchaToken: _riskCaptchaPre!.recaptchaToken,
                      challenge: map['geetest_challenge'],
                      validate: map['geetest_validate'],
                      seccode: map['geetest_seccode'],
                      referer: _riskParams!.refererUrl,
                    ));
            if (error != null) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(error)),
                );
              }
            } else {
              _riskCaptchaKey = captchaKey;
              setState(() {
                _riskSmsSent = true;
                _infoMessage = '验证码已发送至绑定手机号';
              });
            }
          } catch (e) {
            logger.severe('Risk geetest onResult error: $e');
            if (mounted) {
              setState(() {
                _errorMessage = '获取验证码失败: $e';
              });
            }
          }
        },
        onError: (error) {
          logger.severe('Risk geetest error: $error');
          if (mounted) {
            setState(() {
              _errorMessage = '人机验证失败: $error';
            });
          }
        },
      );
      geetest.startCaptcha(registerData);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '风控验证失败: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _riskVerify(BuildContext context) async {
    if (_riskParams == null || !_riskSmsSent) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final (exchangeCode, error) = await BilibiliService.instance
          .then((x) => x.verifySafeCenterSms(
                code: _riskSmsCodeController.text.trim(),
                tmpCode: _riskParams!.tmpCode,
                requestId: _riskParams!.requestId,
                source: _riskParams!.source,
                captchaKey: _riskCaptchaKey,
                referer: _riskParams!.refererUrl,
              ));
      if (error != null || exchangeCode.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error ?? '验证失败')));
        }
        return;
      }
      final tokenResult =
          await BilibiliService.instance.then((x) => x.oauth2AccessToken(exchangeCode));
      if (!tokenResult.isSuccess) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tokenResult.message.isEmpty
                  ? '换取登录态失败，请改用扫码登录'
                  : tokenResult.message)));
        }
        return;
      }
      await BilibiliService.instance
          .then((x) => x.applyLoginSession(tokenResult));
      if (context.mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '风控验证失败: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startSmsCountdown() {
    _smsCountdownTimer?.cancel();
    setState(() {
      _smsCountdown = 60;
    });
    _smsCountdownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _smsCountdown--;
        if (_smsCountdown <= 0) {
          timer.cancel();
        }
      });
    });
  }

  Future<void> _getSmsCode(BuildContext context) async {
    final phone = _phoneController.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      setState(() {
        _errorMessage = '手机号格式不正确';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 官方两段式（真机实测证实）：裸调 sms/send——B 站不要求验证时直接
      // 下发验证码；要求验证时返回 recaptcha_url，必须用 url 内与本次发送
      // 会话绑定的 gt/challenge 做人机验证再带结果重发。captcha 端点预验证
      // 的产物已被 B 站拒收（-105「验证码错误」），不再使用。
      final (captchaKey0, error0, recaptchaUrl) = await BilibiliService
          .instance
          .then((x) => x.sendSmsCaptchaApp(phone, null));
      if (error0 == null && captchaKey0.isNotEmpty) {
        _captchaKey = captchaKey0;
        _startSmsCountdown();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('验证码已发送')),
          );
        }
        setState(() {
          _isLoading = false;
        });
        return;
      }
      if (recaptchaUrl == null) {
        setState(() {
          _errorMessage = error0 ?? '发送失败，请稍后重试';
          _isLoading = false;
        });
        return;
      }
      // recaptcha_url（h5 project-msg-auth/verify）参数：gee_gt /
      // gee_challenge / recaptcha_token（见 chinggg 逆向与 API-collect 文档）
      final qp = Uri.parse(recaptchaUrl).queryParameters;
      final gt = qp['gee_gt'] ?? qp['gt'];
      final challenge = qp['gee_challenge'] ?? qp['challenge'];
      if (gt == null || challenge == null) {
        throw Exception('recaptcha_url 缺少极验参数: $recaptchaUrl');
      }
      _captchaData = CaptchaData(
        token: qp['recaptcha_token'] ?? '',
        gt: gt,
        challenge: challenge,
      );

      final geetest = Gt3FlutterPlugin();
      Gt3RegisterData registerData = Gt3RegisterData(
          gt: _captchaData!.gt!,
          challenge: _captchaData!.challenge!,
          success: true);

      geetest.addEventHandler(
        onShow: (message) {
          logger.info('Geetest challenge dialog shown: $message');
        },
        onResult: (Map<String, dynamic> result) async {
          try {
            logger.info('Geetest verification result: $result');
            final geetestResult = result['result'];
            if (geetestResult == null) {
              setState(() {
                _errorMessage = '人机验证失败，请重试';
              });
              return;
            }
            result = Map<String, dynamic>.from(geetestResult);
            final phone = _phoneController.text.trim();
            final (captchaKey, error, _) =
                await BilibiliService.instance.then((x) => x.sendSmsCaptchaApp(
                      phone,
                      _captchaData,
                      validate: result['geetest_validate'],
                      seccode: result['geetest_seccode'],
                      challenge: result['geetest_challenge'],
                    ));

            if (error != null || captchaKey.isEmpty) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(error ?? '发送失败，请重试')),
                );
              }
            } else {
              _captchaKey = captchaKey;
              _startSmsCountdown();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('验证码已发送')),
                );
              }
            }
          } catch (e) {
            logger.severe('Geetest onResult error: $e');
            if (context.mounted) {
              setState(() {
                _errorMessage = '获取验证码失败: $e';
              });
            }
          }
        },
        onError: (error) {
          logger.severe('Geetest error: $error');
          if (context.mounted) {
            setState(() {
              _errorMessage = '人机验证失败: $error';
            });
          }
        },
      );

      geetest.startCaptcha(registerData);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
      logger.warning('SMS code error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _smsLogin(BuildContext context) async {
    final phone = _phoneController.text.trim();
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
      final loginResult = await BilibiliService.instance.then(
          (x) => x.smsLoginApp(phone, _smsCodeController.text.trim(), _captchaKey!));

      if (loginResult.isSuccess) {
        await BilibiliService.instance
            .then((x) => x.applyLoginSession(loginResult));
        if (context.mounted) {
          Navigator.pop(context, true);
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(loginResult.message.isEmpty
                  ? '登录失败'
                  : loginResult.message)));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
      logger.warning('SMS login error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _initQrcodeLogin({bool useTv = true}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      String? url;
      if (useTv) {
        // TV 端二维码优先（登录态含 access_token，对齐 BiliPai）
        final qrcodeInfo = await BilibiliService.instance
            .then((x) => x.getTvQrcodeLoginInfo());
        if (qrcodeInfo == null || qrcodeInfo.url.isEmpty) {
          throw Exception('获取二维码失败，请重试或使用 Web 二维码');
        }
        url = qrcodeInfo.url;
        _qrcodeAuthCode = qrcodeInfo.authCode;
        _qrcodeIsTv = true;
      } else {
        // Web 端二维码备用
        final qrcodeInfo =
            await BilibiliService.instance.then((x) => x.getQrcodeLoginInfo());
        if (qrcodeInfo == null) {
          throw Exception('Failed to get QR code');
        }
        url = qrcodeInfo.$1;
        _qrcodeKey = qrcodeInfo.$2;
        _qrcodeIsTv = false;
      }

      setState(() {
        _qrcodeUrl = url;
      });

      _qrcodeTimer?.cancel();
      _qrcodePolling = false;
      _qrcodeFinished = false;
      _qrcodeTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        // 已结束（成功/终态）或上次轮询仍在进行时，直接跳过，
        // 保证成功分支的 pop 只发生一次
        if (_qrcodeFinished || _qrcodePolling) {
          return;
        }
        _qrcodePolling = true;
        try {
          if (!mounted || _qrcodeUrl == null) {
            _qrcodeFinished = true;
            timer.cancel();
            return;
          }

          int status;
          if (_qrcodeIsTv) {
            final result = await BilibiliService.instance.then(
                (x) => x.checkTvQrcodeLoginStatus(_qrcodeAuthCode!));
            if (result == null) {
              logger.warning('TV QR poll failed, will retry');
              return;
            }
            if (result.code == 0) {
              _qrcodeFinished = true;
              timer.cancel();
              try {
                await BilibiliService.instance
                    .then((x) => x.applyTvLoginSession(result));
              } catch (e) {
                logger.severe('TV QR login session error: $e');
              }
              if (mounted) {
                Navigator.pop(context, true);
              }
              return;
            }
            status = result.code;
          } else {
            final result = await BilibiliService.instance
                .then((x) => x.checkQrcodeLoginStatus(_qrcodeKey!));
            if (result == null) {
              logger.warning('Web QR poll failed, will retry');
              return;
            }
            if (result == 0) {
              _qrcodeFinished = true;
              timer.cancel();
              try {
                await BilibiliService.instance.then((x) => x.refreshMyInfo());
              } catch (e) {
                logger.severe('Web QR login refreshMyInfo error: $e');
              }
              if (mounted) {
                Navigator.pop(context, true);
              }
              return;
            }
            status = result;
          }

          if (!mounted) {
            _qrcodeFinished = true;
            timer.cancel();
            return;
          }

          switch (status) {
            case 86090:
              setState(() {
                _infoMessage = '已扫码，请在手机端确认';
              });
              break;
            case 86038:
              _qrcodeFinished = true;
              timer.cancel();
              setState(() {
                _errorMessage = '二维码已过期，请重新获取';
                _qrcodeUrl = null;
                _qrcodeKey = null;
                _qrcodeAuthCode = null;
              });
              break;
            case -400:
            case 86103:
              _qrcodeFinished = true;
              timer.cancel();
              setState(() {
                _errorMessage = '扫码登录失败（$status），请重新获取二维码';
                _qrcodeUrl = null;
                _qrcodeKey = null;
                _qrcodeAuthCode = null;
              });
              break;
            default:
              // 未扫码 / 未确认等状态，继续轮询
              break;
          }
        } catch (e) {
          logger.severe('QR poll error: $e');
        } finally {
          _qrcodePolling = false;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _qrcodeUrl = null;
          _qrcodeKey = null;
          _qrcodeAuthCode = null;
        });
      }
      logger.warning('QR code login error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 停止二维码轮询并清空二维码状态（切换登录方式时调用）
  void _stopQrcodePolling() {
    _qrcodeTimer?.cancel();
    _qrcodeUrl = null;
    _qrcodeKey = null;
    _qrcodeAuthCode = null;
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
              if (_qrcodeUrl == null) {
                _initQrcodeLogin();
              }
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
                // 切换到非二维码登录方式时停止轮询并清空二维码状态，
                // 避免后台扫码成功把当前表单页 pop 掉
                _stopQrcodePolling();
              });
            },
            icon: Icon(_loginType == LoginType.sms
                ? Icons.lock_outline
                : Icons.message_outlined),
            label: Text(_loginType == LoginType.sms ? '密码' : '短信'),
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
                  if (_riskParams != null) ...[
                    // ===== 风控验证面板（对齐 BiliPai 安全中心流程） =====
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '本次登录环境存在风险，需使用绑定手机号 $_riskHideTel 完成验证',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _riskSmsCodeController,
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
                          onPressed: _isLoading
                              ? null
                              : () => _riskSendSmsCode(),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(_riskSmsSent ? '重发' : '获取'),
                        ),
                      ],
                    ),
                  ] else ...[
                    TextFormField(
                      controller: _usernameController,
                      autofillHints: const [AutofillHints.username],
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
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_isLoading &&
                            (_formKey.currentState?.validate() ?? false)) {
                          _login(context);
                        }
                      },
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
                  ],
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
                        onPressed: _isLoading || _smsCountdown > 0
                            ? null
                            : () => _getSmsCode(context),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                            _smsCountdown > 0 ? '${_smsCountdown}s' : '获取'),
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
                            onPressed: () => _initQrcodeLogin(),
                            child: const Text('刷新二维码'),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            onPressed: () => _initQrcodeLogin(useTv: false),
                            child: const Text('使用 Web 版二维码'),
                          ),
                        ],
                      ),
                    )
                  else
                    Center(
                      child: _isLoading
                          ? const CircularProgressIndicator()
                          : Column(
                              children: [
                                ElevatedButton(
                                  onPressed: _initQrcodeLogin,
                                  child: const Text('获取二维码'),
                                ),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: _isLoading
                                      ? null
                                      : () => _initQrcodeLogin(useTv: false),
                                  child: const Text('使用 Web 版二维码'),
                                ),
                              ],
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
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.1),
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
                            if (_loginType == LoginType.password &&
                                _riskParams != null) {
                              if (_formKey.currentState?.validate() ??
                                  false) {
                                _riskVerify(context);
                              }
                              return;
                            }
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
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color:
                                  Theme.of(context).colorScheme.onPrimary,
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
    _riskSmsCodeController.dispose();
    _qrcodeTimer?.cancel();
    _smsCountdownTimer?.cancel();
    super.dispose();
  }
}
