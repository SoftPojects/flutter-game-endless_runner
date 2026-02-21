-keep class com.appsflyer.** { *; }
-keep class com.google.android.gms.ads.identifier.** { *; }
-keep public class com.google.android.gms.ads.identifier.AdvertisingIdClient {
   public static com.google.android.gms.ads.identifier.AdvertisingIdClient$Info getAdvertisingIdInfo(android.content.Context);
}
-keep public class com.google.android.gms.ads.identifier.AdvertisingIdClient$Info {
   public java.lang.String getId();
   public boolean isLimitAdTrackingEnabled();
}
