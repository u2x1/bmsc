-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.OpenSSLProvider

# 极验验证码 SDK (sensebot)
# sensebot 内部已混淆并大量使用反射 (Class.forName)，R8 二次混淆/裁剪
# 会导致登录拉起验证弹窗时 ClassNotFoundException 闪退，官方要求保留：
# https://docs.geetest.com/captcha/deploy/client/android
-keep class com.geetest.** { *; }
-dontwarn com.geetest.**
-keepattributes InnerClasses,EnclosingMethod