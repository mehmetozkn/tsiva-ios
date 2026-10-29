# Tsiva iOS SDK

[English](#english) · [Türkçe](#türkçe)

---

## English

Lightweight event tracking for iOS apps. Tsiva batches the events your app records and sends them to your
Tsiva backend. It has no third-party dependencies.

- iOS 15+ (macOS 12+ is also supported, mainly for running the tests)
- Xcode 16+ / Swift 6
- Thread-safe, never crashes or blocks the host app
- Batched uploads with retry and exponential backoff
- Built-in filtering of sensitive properties, privacy manifest included
- Crash reporting for fatal signals and uncaught exceptions

> **Status:** `0.3.0`, an early development release. The public API may still change before `1.0`.

### Installation

**Xcode:** choose **File › Add Package Dependencies…**, enter the URL below and add the `Tsiva` library to your
app target.

```
https://github.com/mehmetozkn/tsiva-ios
```

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/mehmetozkn/tsiva-ios", from: "0.3.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Tsiva", package: "tsiva-ios")])
]
```

### Usage

Configure the SDK once, as early as possible in the app's life:

```swift
import SwiftUI
import Tsiva

@main
struct MyApp: App {
    init() {
        Tsiva.configure(
            apiKey: "YOUR_PROJECT_KEY",
            endpoint: URL(string: "https://your-tsiva-api.example.com")!
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Then record events anywhere, from any thread:

```swift
Tsiva.track("app_opened")

Tsiva.track("checkout_started", properties: [
    "payment_method": "card",
    "item_count": 3,
    "total": 49.90,
    "is_first_order": true
])
```

Property values can be strings, integers, doubles or booleans. Events are uploaded automatically: when 20 events
are queued, every 30 seconds, and when the app moves to the background. To send immediately, call:

```swift
await Tsiva.flush()
```

### Configuration

```swift
Tsiva.configure(TsivaConfiguration(
    apiKey: "YOUR_PROJECT_KEY",
    endpoint: URL(string: "https://your-tsiva-api.example.com")!,
    flushAt: 20,            // events per batch; also triggers an upload
    flushInterval: 30,      // seconds between periodic uploads
    maxQueueSize: 1000,     // oldest events are dropped beyond this
    maxRetries: 3,          // retries for network errors, 429 and 5xx
    logLevel: .debug,       // .none, .error (default), .warning, .debug
    beforeSend: { event in
        var event = event
        event.properties["environment"] = "staging"
        return event        // return nil to drop the event
    }
))
```

`configure` should be called only once. Later calls are ignored and a warning is logged.

### Identifying users

Every event carries an `anonymousId`: a random id created on first launch. It stays the same across launches
and app updates, but changes when the app is deleted and reinstalled, and differs between devices.

To follow a user across reinstalls and devices, pass your own identifier for them:

```swift
Tsiva.identify(userId: account.id)   // e.g. after login; remembered across launches
Tsiva.reset()                        // on logout: forgets the user and starts a new anonymous id
```

Use an opaque id, never an email address or a name. Once you identify users, their data is linked to them:
declare analytics and crash data as **Linked to You** in your App Store privacy details and mention it in your
privacy policy.

### Crash reporting

Crashes are captured automatically once `Tsiva.configure` has run: fatal signals (SIGSEGV, SIGBUS, SIGABRT,
SIGILL, SIGFPE, SIGTRAP; this includes Swift runtime errors such as force-unwrapping `nil` or an array index
out of range) and uncaught Objective-C exceptions. The report is saved to disk at the moment of the crash and
sent on the next launch; the app still terminates normally, so Xcode's and the system's crash reports keep
working.

Each report contains the crashed thread's stack (with the binary and offset of every frame), the binaries'
UUIDs and load addresses, and the device, OS and app version of the session that crashed. Frames are not
symbolicated on the device; to turn an address into a function name, use the matching dSYM:

```bash
atos -arch arm64 -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l <load_address> <address>
```

Only one crash reporter can own the signal handlers. If you use another one (e.g. Crashlytics), disable
Tsiva's:

```swift
Tsiva.configure(TsivaConfiguration(apiKey: "…", endpoint: url, crashReportingEnabled: false))
```

Crashes are not captured while the debugger is attached, because the debugger intercepts the signals first.
Run the app without Xcode attached to test it.

### Privacy

- **Sensitive keys are removed** before an event is queued. By default, any property whose key contains
  `password`, `secret`, `token`, `apikey`, `authorization`, `cookie`, `creditcard`, `cardnumber`, `cvv`, `cvc`,
  `iban`, `ssn`, `email` or `phone` is dropped. Matching ignores case, `_`, `-` and spaces. You can customise
  the list with `redactedPropertyKeys`, and `beforeSend` gives you full control over each event.
- **No device identifiers** are collected. Each install gets a random `anonymousId` that is reset when the app
  is reinstalled. Tsiva does not use IDFA or IDFV, and does not require App Tracking Transparency.
- **Collected context:** SDK version, app bundle ID/version/build, OS name/version, hardware model
  (e.g. `iPhone16,2`), locale and time zone.
- **Privacy manifest:** the package ships a `PrivacyInfo.xcprivacy` that declares product-interaction data
  for analytics and crash data (neither linked to the user nor used for tracking) and its `UserDefaults` usage.
- Events are kept **in memory only**. Events that have not been uploaded yet are lost if the app is
  terminated.

Do not put personal data such as names, emails or free-form user input into event properties.

### Security

The API key is embedded in your app and can be extracted from the binary. Treat it as a **project
identifier, not a secret**: it can only submit events. The backend enforces rate limits, quotas and payload
validation.

### Backend contract

The request format and the retry semantics are documented in [docs/event-schema.md](docs/event-schema.md).

### Development

```bash
swift build
swift test                                    # runs on macOS, no simulator needed
xcodebuild test -scheme Tsiva -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Roadmap

Server-side symbolication (dSYM upload), automatic HTTP instrumentation, performance monitoring and a
persistent (on-disk) event queue are planned for later releases.

### License

Tsiva is released under the [MIT License](LICENSE).

---

## Türkçe

iOS uygulamaları için hafif bir event takip SDK'sı. Tsiva, uygulamanızın kaydettiği event'leri paketler
(batch) halinde toplar ve Tsiva backend'inize gönderir. Üçüncü parti bağımlılığı yoktur.

- iOS 15+ (macOS 12+ da desteklenir, esas olarak testleri çalıştırmak için)
- Xcode 16+ / Swift 6
- Thread-safe; host uygulamayı asla çökertmez veya bloklamaz
- Retry ve üstel bekleme (exponential backoff) ile paketli gönderim
- Hassas property'lerin otomatik filtrelenmesi, privacy manifest dahil
- Ölümcül sinyaller ve yakalanmamış exception'lar için crash raporlama

> **Durum:** `0.3.0`, erken geliştirme sürümü. Public API `1.0`'a kadar değişebilir.

### Kurulum

**Xcode:** **File › Add Package Dependencies…** menüsünü seçin, aşağıdaki adresi girin ve `Tsiva`
kütüphanesini uygulama target'ınıza ekleyin.

```
https://github.com/mehmetozkn/tsiva-ios
```

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/mehmetozkn/tsiva-ios", from: "0.3.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Tsiva", package: "tsiva-ios")])
]
```

### Kullanım

SDK'yı uygulamanın yaşam döngüsünde mümkün olduğunca erken, bir kez yapılandırın:

```swift
import SwiftUI
import Tsiva

@main
struct MyApp: App {
    init() {
        Tsiva.configure(
            apiKey: "PROJE_ANAHTARINIZ",
            endpoint: URL(string: "https://tsiva-api-adresiniz.example.com")!
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Ardından event'leri istediğiniz yerden, herhangi bir thread'den kaydedin:

```swift
Tsiva.track("app_opened")

Tsiva.track("checkout_started", properties: [
    "payment_method": "card",
    "item_count": 3,
    "total": 49.90,
    "is_first_order": true
])
```

Property değerleri string, tam sayı, ondalıklı sayı veya boolean olabilir. Event'ler otomatik gönderilir:
kuyrukta 20 event biriktiğinde, her 30 saniyede bir ve uygulama arka plana geçtiğinde. Hemen göndermek için:

```swift
await Tsiva.flush()
```

### Yapılandırma

```swift
Tsiva.configure(TsivaConfiguration(
    apiKey: "PROJE_ANAHTARINIZ",
    endpoint: URL(string: "https://tsiva-api-adresiniz.example.com")!,
    flushAt: 20,            // paket başına event sayısı; bu sayıya ulaşınca gönderim başlar
    flushInterval: 30,      // periyodik gönderimler arası saniye
    maxQueueSize: 1000,     // bu sayı aşılınca en eski event'ler silinir
    maxRetries: 3,          // ağ hatası, 429 ve 5xx için tekrar deneme sayısı
    logLevel: .debug,       // .none, .error (varsayılan), .warning, .debug
    beforeSend: { event in
        var event = event
        event.properties["environment"] = "staging"
        return event        // event'i engellemek için nil döndürün
    }
))
```

`configure` yalnızca bir kez çağrılmalıdır. Sonraki çağrılar yok sayılır ve bir uyarı loglanır.

### Kullanıcıyı tanımlama

Her event bir `anonymousId` taşır: ilk açılışta üretilen rastgele bir kimlik. Açılışlar ve uygulama
güncellemeleri boyunca aynı kalır; uygulama silinip yeniden yüklenince değişir ve cihazdan cihaza farklıdır.

Bir kullanıcıyı yeniden kurulumlar ve cihazlar arasında takip etmek için kendi kimliğinizi verin:

```swift
Tsiva.identify(userId: account.id)   // ör. girişten sonra; açılışlar arasında hatırlanır
Tsiva.reset()                        // çıkışta: kullanıcıyı unutur ve yeni bir anonim kimlik başlatır
```

E-posta veya isim değil, opak bir kimlik kullanın. Kullanıcıları tanımladığınızda veriler onlara bağlanmış olur:
App Store gizlilik bilgilerinde analitik ve crash verisini **Linked to You** olarak beyan edin ve gizlilik
politikanızda belirtin.

### Crash raporlama

`Tsiva.configure` çalıştıktan sonra çökmeler otomatik olarak yakalanır: ölümcül sinyaller (SIGSEGV, SIGBUS,
SIGABRT, SIGILL, SIGFPE, SIGTRAP; `nil` bir optional'ı zorla açmak veya dizi sınırı dışına çıkmak gibi Swift
çalışma zamanı hataları da buna dahildir) ve yakalanmamış Objective-C exception'ları. Rapor çökme anında diske
kaydedilir ve bir sonraki açılışta gönderilir. Uygulama yine normal şekilde kapanır; Xcode'un ve sistemin
çökme raporları çalışmaya devam eder.

Her rapor; çöken thread'in çağrı yığınını (her çerçevenin binary'si ve offset'iyle), binary'lerin UUID ve
yükleme adreslerini, çöken oturumun cihaz, işletim sistemi ve uygulama sürümünü içerir. Çerçeveler cihazda
sembolleştirilmez; bir adresi fonksiyon adına çevirmek için ilgili dSYM'yi kullanın:

```bash
atos -arch arm64 -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l <load_address> <address>
```

Sinyal yakalayıcıları aynı anda yalnızca bir crash raporlayıcı kullanabilir. Başka bir araç (ör. Crashlytics)
kullanıyorsanız Tsiva'nınkini kapatın:

```swift
Tsiva.configure(TsivaConfiguration(apiKey: "…", endpoint: url, crashReportingEnabled: false))
```

Debugger bağlıyken çökmeler yakalanmaz, çünkü sinyalleri önce debugger alır. Denemek için uygulamayı Xcode
bağlı olmadan çalıştırın.

### Gizlilik

- **Hassas anahtarlar** event kuyruğa alınmadan önce silinir. Varsayılan olarak anahtarında `password`,
  `secret`, `token`, `apikey`, `authorization`, `cookie`, `creditcard`, `cardnumber`, `cvv`, `cvc`, `iban`,
  `ssn`, `email` veya `phone` geçen her property gönderilmez. Eşleştirmede büyük/küçük harf, `_`, `-` ve boşluk
  dikkate alınmaz. Listeyi `redactedPropertyKeys` ile özelleştirebilirsiniz; `beforeSend` ise her event
  üzerinde tam kontrol sağlar.
- **Cihaz tanımlayıcısı toplanmaz.** Her kuruluma, uygulama yeniden yüklendiğinde sıfırlanan rastgele bir
  `anonymousId` atanır. Tsiva IDFA veya IDFV kullanmaz ve App Tracking Transparency izni gerektirmez.
- **Toplanan bağlam bilgisi:** SDK sürümü, uygulamanın bundle ID/sürüm/build bilgisi, işletim sistemi
  adı/sürümü, donanım modeli (ör. `iPhone16,2`), dil/bölge ve saat dilimi.
- **Privacy manifest:** Paket, analitik amaçlı ürün etkileşimi verisini ve crash verisini (ikisi de kullanıcıya
  bağlı değil, takip için kullanılmaz) ve `UserDefaults` kullanımını beyan eden bir `PrivacyInfo.xcprivacy`
  içerir.
- Event'ler **yalnızca bellekte** tutulur. Uygulama kapatılırsa henüz gönderilmemiş event'ler kaybolur.

Event property'lerine isim, e-posta veya kullanıcının serbest metin girdisi gibi kişisel veriler koymayın.

### Güvenlik

API anahtarı uygulamanın içine gömülüdür ve uygulama paketinden çıkarılabilir. Bu anahtarı **gizli bir
anahtar değil, proje tanımlayıcısı** olarak düşünün: yalnızca event göndermeye yarar. Rate limit, kota ve
payload doğrulaması backend tarafında uygulanır.

### Backend sözleşmesi

İstek formatı ve tekrar deneme kuralları [docs/event-schema.md](docs/event-schema.md) dosyasında anlatılmıştır.

### Geliştirme

```bash
swift build
swift test                                    # macOS'ta çalışır, simülatör gerekmez
xcodebuild test -scheme Tsiva -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Yol haritası

Sunucu tarafında sembolleştirme (dSYM yükleme), otomatik HTTP izleme, performans takibi ve kalıcı (disk
tabanlı) event kuyruğu sonraki sürümlerde planlanmaktadır.

### Lisans

Tsiva, [MIT Lisansı](LICENSE) ile yayınlanmaktadır.
