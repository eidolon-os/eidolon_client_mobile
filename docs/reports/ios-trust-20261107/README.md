# iOS 客户端如何信任 Host 的两条 TLS 通道：调研与方案（2026-11-07）

- **问题**：Owner 信任材料和 Host 的两张 TLS 证书已经改为按设备生命周期签发 99 年、不续签（eidolon_ops `1a1198c`/`11cdf14`、eidolon_admin `a1fc024`、docs `5e2e692`）。Apple 支持文档 103769 要求 TLS 服务器证书有效期不超过 825 天。将来做 iOS/macOS 客户端时，怎样做才能和"长期信任锚 + 签一次"这套架构一致，而不是为 Apple 单开一条 825 天、自动续签的链路。
- **工作方式**：只读代码，没有改任何产品代码。凡是关于 Apple 平台行为的结论都附一手出处（见文末"资料来源"）。另外在本机 macOS 26.5.2 上做了实测，脚本放在 [`probe/`](probe/)。本机只装了 Command Line Tools，没有 Xcode 和 iOS 模拟器，所以**没有在 iOS 上实测**。iOS 上的结论来自 Apple 文档、Apple 员工的回答，以及 Apple 开源的 Security 源码；iOS 和 macOS 用的是同一套信任评估代码。
- **状态**：
  - 结论已定，采用方案 (a)。设计文档 §3.6.1 和 eidolon_ops 的证书报告 §3 已同步改写（§6）。
  - iOS 客户端整体延后（2026-11-07 确认），包括 BLE 配网。真机验证还没做，因为暂时没有设备。启动 iOS 客户端时，先按 §5 的清单验证，全部符合预期再按 §3.4 实现。
- **证据标记**：
  - 〔文档〕Apple 开发者文档、技术说明、支持文档、发布说明、WWDC。
  - 〔DTS〕Apple 开发者论坛上 Apple 员工的回答，主要是 DTS 工程师 Quinn "The Eskimo!" 和 Matt Eaton。
  - 〔源码〕Apple 开源代码：apple-oss-distributions/Security（tag Security-61901.120.67）、apple/swift-certificates 1.21.1。
  - 〔实测〕本机 macOS 实测。
  - 〔推断〕没有一手出处，是我的推理。

## 0. 结论

**推荐方案 (a)：Host 证书保持 99 年不动。iOS 客户端和 Android 一样自己按长期锚校验：Hub 按 Owner root 校验证书链并核对主机名，Local API 比对 SPKI pin。不需要为 Apple 开 825 天的链路，也不需要任何要向审核说明理由的 ATS 例外。**

理由如下。

1. **825 天、SAN、EKU 这些要求只存在于 Apple 的 TLS 服务器信任策略 `SecPolicyCreateSSL` 里**，并不是所有 TLS 连接都必须满足的硬约束。
   - 〔DTS〕Quinn 在 thread 773796 里说这些限制由 TLS 策略施加，并且明确写了："The Basic X.509 policy does not enforce them"。同一帖还说：825 天对所有 CA 生效，包括 App 自带的锚；398 天只对系统预装的 CA 生效。
   - 〔源码〕这条检查叫 `OtherTrustValidityPeriod`，只量叶证书。用 `SecTrustSetAnchorCertificates` 设进去的锚同样受它约束。
   - 〔实测〕私有根做锚、用 SSL 策略时：825 天的叶证书通过，826 天和 99 年的都被拒，错误为 `errSecCertificateValidityPeriodTooLong`。换成 `SecPolicyCreateBasicX509` 后，99 年的通过。
2. **iOS 允许 App 自己做服务器信任认证，Apple 也有对应的文档和建议。**
   - URLSession 和 Network.framework 默认都按 SSL 策略校验，所以"把 Owner root 设成锚就完事"这条最省事的路在 iOS 上走不通。
   - 但两个框架都留了让 App 自己判定的入口：URLSession 的 `urlSession(_:didReceive:completionHandler:)`，Network.framework 的 `sec_protocol_options_set_verify_block`，以及 iOS 26 新 Swift API 里的 `TLS().certificateValidator`。在入口里改用 BasicX509 策略并只信 Owner root，或者直接比对 SPKI，就不会经过上面那些检查。
   - 〔文档〕Apple 的 "Performing Manual Server Trust Authentication" 明确列出两种适合自行校验的情况：接受系统不认的证书，以及 pin 自己控制的密钥。
   - 〔DTS〕Quinn 的 "TLS For Accessory Developers"（thread 703234）专门讲局域网配件。他给的做法是：私有 CA，App 内置根证书，`SecPolicyCreateBasicX509`，`SecTrustSetAnchorCertificatesOnly(true)`，然后自己核对叶证书里的身份。Eidolon 的 Hub 正是这种局域网配件。
3. **ATS 不会挡这条路，只要端点是 `.local` 名或局域网 IP。**
   - ATS 只作用于 URLSession。对受 ATS 保护的域名，在代理里放宽信任是无效的，这一点〔文档〕〔实测〕都确认了。
   - `.local` 名和局域网 IP 不受 ATS 约束。不过 iOS 17 起，IP 地址的说法在文档里有歧义，见 §2.3。
   - 在 Info.plist 里设 `NSAllowsLocalNetworking = YES` 即可。这个键不在需要向审核说明理由的 ATS 例外清单里〔文档〕。
4. **方案 (b)（为 Apple 降回 825 天并自动续签）省不掉自定义校验。**
   - Owner root 不在系统信任库里，iOS 端照样要在代理里设锚。
   - Local API 用的是自签证书，按 IP 访问，而 IP 随 DHCP 变化，照样只能比对 SPKI。
   - (b) 唯一的变化是 Hub 那一路把 BasicX509 换成 SSL 策略。代价是 Host 要重新长出续签逻辑，可是据 2026-11-06 Owner 目录调查的记录，Pi 部署时 Owner 签名私钥只在控制端，Host 自己续签不了 `hub.crt`。而且客户端从此要跟着 Apple 今后的 WebPKI 政策走。
5. **(c) 里的几种备选都不比 (a) 好。**
   - Apple 的 TLS 栈不支持 RFC 7250 裸公钥。
   - TLS-PSK 只有 Network.framework 的旧 API 支持，而且只到 TLS 1.2。URLSession 和 iOS 26 的新 Swift API 都不支持。
   - 用 TLS exporter 做通道绑定是做得到的，但没有必要：Local API 的 SPKI 已经由 Host 的 Ed25519 身份密钥签名，并且绑进了配对 PAKE 的上下文，再绑一层并不增加安全性。

真正需要另外决定的事有两件，都和证书有效期无关。iOS 客户端整体延后（2026-11-07 确认），这两件都等启动 iOS 客户端时一起做：

- **BLE 配网里的 TLS-over-GATT**：Android 用 `SSLEngine` 直接在 GATT 上跑 TLS，pin 的是 Local API 的同一把公钥（`BleCommissioningManager.kt`）。iOS 没有能在任意字节流上跑 TLS 的一手 API〔DTS〕，需要另外选型，见 §3.5。Android 在添加 Host、以及 Host 公钥变化后重新确认身份时都会用到 BLE，所以 iOS 客户端一开始就要有它，不能比其余部分更晚。
- **本地网络权限**：两条通道和 mDNS 发现都需要用户授权"本地网络"。授权文案、首次触发的时机、被拒后的提示都要设计，见 §2.1。

## 1. Apple 的证书要求在哪些代码路径上强制（问题 1）

### 1.1 要求本身

| 要求 | 出处 | 适用范围 | Hub 叶证书（99 年） | Local API 证书（99 年） |
|---|---|---|---|---|
| 有效期不超过 825 天（只针对 NotBefore 晚于 2019-07-01 的证书） | 〔文档〕103769 | 所有 TLS 服务器证书，包括私有 CA〔DTS 773796〕 | **不满足** | **不满足** |
| 有效期不超过 398 天 | 〔文档〕102028 | 只针对系统预装根；用户或管理员添加的根不受影响 | 不适用 | 不适用 |
| 服务器名必须写在 SAN 里，CN 不再被信任 | 〔文档〕103769 | 同上 | 满足（DNS SAN 为 `.local` 名） | **不满足**（只有 URI SAN） |
| EKU 必须包含 serverAuth（只针对 NotBefore 晚于 2019-07-01 的证书） | 〔文档〕103769 | 同上 | 满足 | **不满足**（没有 EKU） |
| RSA 密钥至少 2048 位，签名哈希用 SHA-2 | 〔文档〕103769 | 同上 | P-256、SHA-256，满足 | 满足 |
| ATS 额外要求：TLS 1.2 及以上、ECDHE 前向保密、AES、ECC 至少 256 位、SHA-2 | 〔文档〕Preventing Insecure Network Connections | 只针对受 ATS 约束的 URLSession 连接 | 满足 | 满足 |

〔源码〕补充两点：EC 密钥至少 256 位的要求在 SSL 策略里同样存在（103769 没写 EC）；证书透明度（CT）只对系统根要求。

两张证书的实际参数来自 eidolon_ops `owner_domain_assets._host_tls` 和 eidolon_admin `bootstrap/tls_identity.py`：
- Hub 叶证书：P-256，SHA-256，`BasicConstraints` 为 CA=false 且标为 critical，SAN 只有一个 DNS 名，EKU 为 serverAuth 且标为 critical。
- Local API 证书：P-256 自签，`BasicConstraints` 为 CA=false，SAN 只有 `urn:eidolon:host:<id>`，没有 EKU。

### 1.2 这些检查属于哪个策略〔源码〕〔DTS〕

- **`SecPolicyCreateSSL(true, name)`** 包含以下检查（`OSX/sec/Security/SecPolicy.c` 中的 `SecPolicyCreateSSL_internal` 和 `set_ssl_validity_periods`）：
  - 基础 X.509 检查；
  - 强密钥长度（RSA ≥ 2048、EC ≥ 256）；
  - 禁用弱哈希；
  - 有效期上限：`SystemTrustValidityPeriod`（系统根，398/825 天）和 `OtherTrustValidityPeriod`（其他锚，825 天）；
  - `ServerAuthEKU`；
  - 主机名检查：只看 SAN、忽略 CN；连接目标是 IP 时，按 iPAddress SAN 逐字节比较；
  - 系统根的 CT 要求。
- **`SecPolicyCreateBasicX509()`** 只包含基础 X.509 检查：关键扩展、BasicConstraints、签名、有效期起止、弱密钥。没有有效期上限，不查 SAN 和主机名，也不查 EKU（同一文件的 `SecPolicyCreateBasicX509`）。Quinn 在 thread 773796 里也是这么说的。
- **825 天检查的触发条件**（`trust/trustd/SecPolicyServer.c`）：
  - 只量叶证书；
  - 只要锚不是系统根就适用，包括 `SecTrustSetAnchorCertificates` 设进去的锚；
  - 唯一的例外是用户信任存储，也就是通过描述文件安装、并由用户手动信任的证书。
- **EKU 检查**对 App 设的锚同样适用（NotBefore 晚于 2019-07 的证书）。

### 1.3 本机实测（macOS 26.5.2，[`probe/trust_eval.swift`](probe/trust_eval.swift)）

用 openssl 按 Host 的参数造了一套证书：Owner root（P-256，CA，99 年）、Hub 叶证书（SAN `eidolon-hub-test.local`，EKU serverAuth，分别签 825、826 天和 99 年）、Local API 风格的自签证书（只有 URI SAN，没有 EKU，99 年）。所有评估都是 `SecTrustSetAnchorCertificates` 加 `SecTrustSetAnchorCertificatesOnly(true)`。

| 证书 | `SecPolicyCreateSSL(true, 主机名)` | `SecPolicyCreateSSL(true, nil)` | `SecPolicyCreateBasicX509()` |
|---|---|---|---|
| Hub 叶证书 825 天 | 通过 | 通过 | 通过 |
| Hub 叶证书 826 天 | 拒：`OtherTrustValidityPeriod` | 拒：同左 | 通过 |
| Hub 叶证书 99 年 | 拒：`OtherTrustValidityPeriod` | 拒：同左 | **通过** |
| Local API 自签 99 年（以证书自身为锚） | 拒（主机名填 IP）：`OtherTrustValidityPeriod`、`SSLHostname`、`ServerAuthEKU` | 拒：`OtherTrustValidityPeriod`、`ServerAuthEKU` | **通过** |

错误码都是 -67901，即 `errSecCertificateValidityPeriodTooLong`。另外，从 `SecCertificateCopyKey` 和 `SecKeyCopyExternalRepresentation` 拿到的是 65 字节的 X9.63 公钥，不是 SPKI〔文档〕〔DTS 761130〕。再经 CryptoKit 的 `P256.Signing.PublicKey(x963Representation:).derRepresentation` 得到 91 字节的 SPKI DER，它的 SHA-256 与 openssl 算出的 pin **逐字节一致**。CryptoKit 文档没有写明 `derRepresentation` 就是 SPKI，这一点是靠实测确认的。

### 1.4 逐条代码路径

| # | 路径 | 实际用的策略 | 99 年 Hub 叶证书 | 99 年 Local API 证书 | 能否合规地自行校验 | 依据 |
|---|---|---|---|---|---|---|
| 1 | URLSession 默认处理（不实现代理，或返回 `performDefaultHandling`） | SSL 策略 + 系统根 | 拒（根不在系统信任库） | 拒 | — | 〔实测〕-1202 |
| 2 | 在 URLSession 代理里设 Owner root 为锚，但仍用 SSL 策略 | SSL 策略 + 自带锚 | **拒（825 天）** | 拒（825 天、EKU、主机名） | 否 | 〔DTS 773796〕〔源码〕〔实测〕 |
| 3 | 在 URLSession 代理里 `SecTrustSetPolicies(BasicX509)`，设锚、只信自带锚，调 `SecTrustEvaluateWithError`，再自己查主机名和 EKU | BasicX509 | 通过 | — | **是** | 〔DTS 703234〕〔实测〕 |
| 4 | 在 URLSession 代理里只比对叶证书的 SPKI | 不经任何策略 | — | 通过 | **是** | 〔文档〕Performing Manual…、TN2232 "Trusting One Specific Certificate"；〔实测〕 |
| 5 | 3 或 4，但 URL 主机是普通域名，受 ATS 约束 | ATS 要求默认评估必须先通过 | 拒 | 拒 | 否；除非用 `NSExceptionDomains` 加 `NSExceptionAllowsInsecureHTTPLoads`，而这需要向审核说明理由 | 〔文档〕〔DTS 67493〕〔实测〕 |
| 6 | 3 或 4，URL 主机是 `.local` 名或局域网 IP | 不受 ATS 约束（见 §2.3） | 按 3 通过 | 按 4 通过 | **是** | 〔文档〕NSAllowsLocalNetworking；〔实测〕 |
| 7 | Network.framework 默认（不设 verify block） | 〔推断〕SSL 策略。已发布的源码里看不到 Network.framework 的默认路径；已发布的 Secure Transport 和 coreTLS 源码用的是 SSL 策略 | 拒 | 拒 | — | 〔源码〕〔推断〕 |
| 8 | Network.framework 的 `sec_protocol_options_set_verify_block`（iOS 12+），或 iOS 26 的 `TLS().certificateValidator` | 由 App 自己决定 | 通过 | 通过 | **是**，且不受 ATS 约束 | 〔文档〕〔DTS 768961、807854〕；〔实测〕BasicX509 通过，SSL 策略被拒（-9808） |
| 9 | ATS 的 `NSPinnedDomains` | 静态写在 Info.plist 里，在默认评估之外再加一层，只能收紧 | 不适用：既不能放宽，pin 也无法动态下发 | 不适用 | 否 | 〔文档〕Identity Pinning、NSPinnedDomains |
| 10 | Flutter `dart:io` 的 `HttpClient`/`SecureSocket` 加 `SecurityContext.setTrustedCertificatesBytes` | Dart SDK 在 iOS/macOS 上用 `SecPolicyCreateSSL`，并把 App 提供的证书设为锚 | 〔推断〕拒（825 天），只能落到 `badCertificateCallback` | 〔推断〕拒 | 不适合 | dart-lang/sdk `runtime/bin/security_context_macos.cc`（commit `223176c250`）；非 Apple 一手，未在 iOS 实测 |
| 11 | swift-certificates `Verifier`（`RFC5280Policy` 加 `ServerIdentityPolicy`） | 库内自带实现，没有有效期上限 | 通过 | — | 是 | 〔源码〕apple/swift-certificates 1.21.1 |

**URLSession 在代理返回之后不会再按 SSL 策略复评。** 〔实测〕在不受 ATS 约束的情况下，代理用 BasicX509 在一份副本上评估通过后，哪怕把原来那个 SSL 策略的 trust 对象原样交回，连接也照样成功。也就是说，判定完全由代理做出。

**iOS 上读 SAN 需要自己解析。** `SecCertificateCopyValues` 只有 macOS 有（SDK 头文件标注 `__IPHONE_NA`）。Quinn 说 iOS 没有 ASN.1 API，建议用 SwiftASN1〔DTS 750337〕。实际做法可以用 Apple 的 swift-certificates（它基于 SwiftASN1）解析叶证书的 SAN 和 EKU。

### 1.5 Apple 官方是否认可这种做法

**认可的依据：**
- 〔文档〕"Performing Manual Server Trust Authentication" 列出两种适合自行评估的情况：一是接受系统本会拒绝的凭据（例子是自签证书），二是 pin 一组自己控制的密钥或证书。处理方法是：只处理 `NSURLAuthenticationMethodServerTrust` 这类挑战，并核对 `protectionSpace.host`；判定可信就用 `URLCredential(trust:)` 调 `.useCredential`，否则 `.cancelAuthenticationChallenge`。同一篇的 Note 写明：对受 ATS 保护的域名只能收紧，不能放宽。
- 〔文档〕TN2232（已归档）讲了两件事：一是用 `SecTrustSetAnchorCertificates` 设私有 CA 的根；二是"Trusting One Specific Certificate"，适用于点对点场景，前提是通过 App 自己的可信渠道拿到对端证书。后者正是 Local API 的情形：可信渠道是 Host 用 Ed25519 签名的 endpoint 文档，再加上 PAKE。
- 〔DTS〕Quinn 的 "TLS For Accessory Developers"（703234，2022-03）明确用 `SecPolicyCreateBasicX509`。理由是 TLS 策略要检查 DNS 名，这对局域网配件不合适。代码里设私有 CA 为锚、只信这个锚，然后再核对叶证书里的设备身份。Hub 的做法与此一致，只是我们额外保留了主机名核对，和 Android、Reachy、ESP32 的语义对齐。
- 〔文档〕Apple 建议 pin 公钥而不是证书，并且优先 pin CA 的公钥。Hub 锚在 Owner root（CA）上，Local API pin 的是公钥，都符合这条建议。

**需要如实列出的反面意见：**
- 〔DTS 773796〕Quinn 说，自定义评估"应当"使用 TLS 策略。他总体上强烈不建议用自定义锚，理由是代码一旦写错就失去全部 TLS 保护。他更推荐的做法是公共 CA 证书加上 pin。不过这条建议针对的是互联网服务器。`.local` 名和私网 IP 拿不到公共 CA 签发的证书（这是 CA/B Forum Baseline Requirements 对内部名称和保留 IP 的规定，不是 Apple 的出处），所以这里适用的是他那篇配件帖子。
- 〔DTS 720477〕自签叶证书偏离了常规做法，Quinn 不推荐。Local API 的自签证书只是一层外壳。它的信任来源是 Host 身份签名和 PAKE，这比 Quinn 认为"可以接受的最低限度"、也就是首次连接时信任（TOFU，他称为 SSH 做法），还要强。
- 应对写错代码的风险：两个评估器写成纯函数，用固定的测试证书做正反两类测试，见 §4。

**App Store 方面：**
- 我没有找到任何禁止自定义信任评估的 Apple 条款。
- 〔DTS 818807〕Quinn 说，App Review 对使用哪种 TLS 实现没有要求。
- 只要端点是 `.local` 名或局域网 IP，就不需要任何要向审核说明理由的 ATS 例外（§2.3）。

## 2. 本地网络相关限制（问题 2）

### 2.1 本地网络权限（iOS 14+）〔文档〕TN3179（2026-10-06 修订）、WWDC20 10110、WWDC24 10123

**哪些操作需要授权：**
- 主动发起的、到本地网络地址的 TCP 连接；
- 发送 UDP（单播、组播、广播都算）；
- 解析 `.local` 名；
- Bonjour 的注册、浏览、解析。

这个限制作用于**所有网络 API**，包括 URLSession、Network.framework 和 BSD Sockets。监听端口、WKWebView 和 SFSafariViewController 不在此列。

**用户还没答复时的行为：**
- 系统可能在用户答复之前就直接拒绝这次操作。建议用 `NWConnection`，或者开启 URLSession 的 `waitsForConnectivity`，让连接等到授权后再继续。
- App 在后台、且用户还没有做过选择时，会被静默拒绝，不弹窗。

**检测是否被拒：**
- 没有通用的查询 API（FB8711182）。
- `NWConnection` 会进入 `.waiting` 状态，原因是 `NWPath.UnsatisfiedReason.localNetworkDenied`，授权后会自动重试。
- Bonjour 操作会返回 `kDNSServiceErr_PolicyDenied`（-65570）。
- URLSession 被拒时具体返回什么错误码，文档没有写。

**模拟器不实施本地网络权限**，必须在真机上测试。

**对 Eidolon 的影响：**
- 解析 Hub 的 `.local` 名并连接 8443；
- 按 IP 连接 Local API 的 9002；
- 浏览 `_eidolon-local-api._tcp`。

这三件事都需要授权。首次触发应放在前台、在用户明确要"添加 Host"的那一步。

**Info.plist 需要的键：**
- `NSLocalNetworkUsageDescription`：必须有。用了 Bonjour 键却缺这一项，访问会被直接阻止〔WWDC24 10123〕。文案要按 App Review Guidelines 5.1.1(ii) 写清楚用途。
- `NSBonjourServices`：必须列出 `_eidolon-local-api._tcp`。WWDC20 10110 的演示里，缺了这个键会得到 NoAuth 错误。只解析一个普通的 `.local` 主机名是否也需要在这里登记，文档没有写。
- 组播 entitlement（`com.apple.developer.networking.multicast`）**不需要**。它只在收发原始 UDP 组播/广播、或者浏览任意服务类型时才需要。浏览已声明的服务类型、做单播连接都不需要〔文档〕TN3179、entitlement 页。
- BLE 需要 `NSBluetoothAlwaysUsageDescription`。

### 2.2 `.local` 名的解析

- iOS 的系统解析器会处理 `.local`。把 `.local` 名放进 URL 或交给 `NWConnection`，系统会走 mDNS 解析〔DTS 46413、114809〕；TN3179 把"解析 `.local` 名"列为需要授权的操作，也说明了这一点。这和 Android 不同：Android 的 `getaddrinfo` 不解析 `.local`，所以 Android 才需要 `connectionAddress` 地址提示（见 `LocalApiAnnouncement.kt` 的注释）。在 iOS 上，Hub 请求可以直接用 `.local` URL，地址提示只作为后备。
- `.local` 名不代表身份，它可能解析到另一台设备〔DTS 703234〕。这和我们的设计一致：信任来自 Owner root 和 SAN，而不是名字解析的结果。

### 2.3 ATS 对 `.local` 和 IP 的规则

**文档怎么说：**
- 〔文档〕NSAllowsLocalNetworking 页面：
  - iOS 10 到 16，ATS 默认放行无点主机名、`.local` 名和 IP 地址；
  - iOS 17、macOS 14 起，ATS 默认不再放行 IP 地址，需要在 `NSExceptionDomains` 里逐个列出 IP 或 CIDR；
  - `NSAllowsLocalNetworking` 会放行无点主机名、`.local` 名和 IP 这三类；
  - Apple 建议即使不需要，也把它设为 YES，作为"意图声明"。Quinn 在 703234 里也是这么说的。
- 〔文档〕iOS 17 和 macOS 14 的发布说明（101967030）措辞不同：对 iOS 17 及以后链接的 App，ATS 默认要求连接**外部** IP 地址时使用安全连接。
- 〔文档〕需要向审核说明理由的 ATS 例外是：`NSAllowsArbitraryLoads` 系列、`NSExceptionAllowsInsecureHTTPLoads`、`NSExceptionMinimumTLSVersion`（Preventing Insecure Network Connections 的 "Provide Justification for Exceptions" 一节）。**`NSAllowsLocalNetworking` 不在这个清单里。**

**〔实测〕macOS 26.5.2：** 测试程序用 26 SDK 链接，嵌入 Info.plist 以启用 ATS，并关掉系统代理。脚本见 [`probe/ats_local_names.swift`](probe/ats_local_names.swift) 和 [`probe/ats_fqdn.swift`](probe/ats_fqdn.swift)。

| 目标 | ATS 为空字典 | `NSAllowsLocalNetworking = YES` |
|---|---|---|
| http 到普通域名（`127.0.0.1.nip.io`） | 拒，-1022（说明 ATS 确实生效） | 拒，-1022 |
| http 到局域网 IP `192.168.100.6` | 放行 | 放行 |
| http 到本机 `.local` 名 | 放行 | 放行 |
| https 到局域网 IP，代理里自行校验（99 年 Hub 证书、99 年 Local API 证书） | 通过 | 通过 |
| https 到 `.local` 名，代理里自行校验（同上） | 通过 | 通过 |
| https 到普通域名，代理里自行校验；825 天证书、主机名匹配、SSL 策略加自带锚也判定可信 | **拒，-9802** | **拒，-9802** |
| 同上，但加了 `NSExceptionDomains` 和 `NSExceptionAllowsInsecureHTTPLoads` | 通过（99 年证书也通过） | — |

**结论：**
- 对普通域名，ATS 只认系统根，App 设的锚不算数。
- `.local` 名和私网 IP 在 macOS 上实测都不受 ATS 约束。这和"外部 IP"的措辞相符，但和 NSAllowsLocalNetworking 页面上"IP 地址"的写法不完全一致。
- **建议：** Info.plist 里设 `NSAllowsLocalNetworking = YES`，不加 `NSAllowsArbitraryLoads`，也不加 `NSExceptionDomains`。上真机时先验证"局域网 IP 加代理自行校验"能否通过。如果 iOS 真把私网 IP 也纳入 ATS，Local API 就改走 Network.framework（它不受 ATS 约束），而不是去加一个需要说明理由的 IP 例外。
- Hub 将来如果改用普通域名（比如走公网 DNS），这个问题就会出现：需要 `NSExceptionAllowsInsecureHTTPLoads`（要说明理由），或者改走 Network.framework。

### 2.4 按 IP 直连 HTTPS

- **URLSession 可以按 IP 连接**，信任判定由代理决定〔实测〕。但 `Host` 是保留头，App 设置的值系统可能忽略或覆盖〔文档〕NSURLRequest "Reserved HTTP headers"。所以无法做到"连 IP、但发 `Host: *.local`"。
- **SNI**：Apple 没有一手说明按 IP 连接时是否发送 SNI。RFC 6066 §3 规定 SNI 里不能放 IP 字面量（非 Apple 出处）。
- **Hub 能否按 IP 访问**：Hub 的 LAN ingress（eidolon_ops `lan_ingress.py`）只加载一张证书，既不按 SNI 也不按 Host 头路由，所以按 IP 访问 Hub、由评估器核对预期的 `.local` 名，在 ingress 这一层是可行的。ingress 后面的 Hub 服务是否依赖 Host 头，我**没有核实**。
- **完全等价于 Android 地址提示的做法**是 Network.framework 的 `sec_protocol_options_set_tls_server_name`：连 IP，同时用指定的名字做证书校验〔文档〕。代价是要自己处理 HTTP 报文。
- **TLS 会话缓存**：服务器信任挑战的结果是会话级的，处理一次就对该会话里所有任务生效〔文档〕Handling an Authentication Challenge。TLS 会话缓存还可能掩盖 pin 的变化〔DTS 672291〕。所以应该每个请求用一个 ephemeral 会话，或者按"origin + 锚/pin"各建一个会话，pin 变化时作废。这对应 Android 每次请求后 `evictAll()` 连接池的做法。
- **系统代理**：本机设置了 HTTP 代理，在不禁用代理的情况下，`.local` 请求被代理接管、返回了 502。把 `connectionProxyDictionary` 设为 `[:]` 之后恢复直连〔实测，macOS〕。Quinn 也提醒过，遇到 TLS 检查代理时 pin 必然失败〔DTS 798054〕。所以局域网会话应该禁用代理。`[:]` 表示"不用代理"这个语义，我没有找到 Apple 文档的明文说明，只做了实测。

## 3. 方案比较（问题 3）

| 方案 | 安全性 | 实现复杂度 | 与"长期锚 + 签一次"是否一致 | App Store 风险 |
|---|---|---|---|---|
| **(a) iOS 自行按 Owner root / SPKI 校验，证书保持 99 年（推荐）** | 与 Android、Reachy、ESP32 相同：链到 Owner root 并核对主机名；Local API 由 Ed25519 签名加 PAKE 认证的 SPKI pin 保证 | 低：两个纯函数评估器，加一个 URLSession 代理 | **完全一致**：客户端只认长期锚，不看证书有效期 | 低：只用公开 API；只需 `NSAllowsLocalNetworking`，不需要说明理由 |
| (b) 为 Apple 单开一条 ≤ 825 天、自动续签的链路 | 不比 (a) 高 | 高：Host 要续签、热加载；Pi 上还要为 Host 新增一个能签 TLS 证书的委托 CA；iOS 端仍然要写自定义评估 | **不一致**：重新引入续签，到期失败的风险回来了 | 同 (a)，没有额外收益 |
| (c1) RFC 7250 裸公钥 | — | 不可行 | 本应最一致 | Apple 的 TLS 栈不支持 |
| (c2) Network.framework TLS-PSK | 依赖共享密钥，只有 TLS 1.2 | 中到高 | 不一致：信任落在每对设备之间的共享秘密上 | 本身没问题，但 URLSession 和新 Swift API 都不支持 |
| (c3) 在 TLS 之上用 Ed25519 签 TLS exporter 做通道绑定 | 比 (a) 略强，但对现有威胁模型没有增益 | 高：要用 Network.framework、自己处理 HTTP，Host 侧也要改 | 一致 | 低 |
| (c4) 用描述文件把 Owner root 装进系统信任 | 差：Safari 等全系统都会信任这个根 | 低 | 不一致 | 用户体验差 |
| (c5) 自带 TLS 栈（SwiftNIO SSL / BoringSSL） | 取决于实现 | 高 | 一致 | 允许，但出口合规问题要答 "Yes" |

### 3.1 (a) 自行校验（推荐）

- **安全性**：信任根和 Android 完全相同。
  - Hub：证书链必须终止于 Owner root（只信这一个锚），SAN 里的 DNS 名必须等于 descriptor 里给出的 Hub 主机名，EKU 必须包含 serverAuth，叶证书不能是 CA。
  - Local API：叶证书公钥的 SHA-256 必须等于 pin。pin 来自 Host Ed25519 签名的 endpoint 文档，并经过配对 PAKE 认证。
  - 少掉的只有 Apple 的"有效期上限"这一项，而它在我们的模型里本来就没有安全含义（见 ops 报告 §0）。
- **复杂度**：iOS 端写一个 Swift 平台通道，实现和 Android 相同的 `PinnedHttpsProtocol` v1。现在 `pinned_http_client.dart:139` 对非 Android 平台直接返回 `unsupportedPlatform`。具体要点见 §3.4。
- **一致性**：Host 端零改动。设计文档 §3.6.1 里那条"已知决策点"可以落定为：Apple 客户端自行按锚校验，不走 SSL 策略。
- **风险**：自定义评估的代码一旦写错，就等于没有 TLS〔DTS〕。用正反两类固定测试证书来覆盖（§4）。

### 3.2 (b) 为 Apple 单开 ≤ 825 天、自动续签的链路

**由谁签发：**
- Hub 叶证书由 Owner root 签发。Mac 产品的 Owner 材料就在本机（`config_root/owner-domain-private`），`start` 时可以重签。
- 但据 2026-11-06 Owner 目录调查的记录，Pi 部署时 Owner 签名私钥只在运行 ops 的控制端，Host 自己续签不了。要在 Pi 上自动续签，就得给 Host 发一个能签出 Owner 信任的 TLS 证书的**委托中间 CA**。这个 CA 本身也有生命周期，泄露后的影响面比一张叶证书大。
- 另外，常驻进程只在启动时加载证书，续签后还要热加载或重启。这正是 ops 报告第二版里明确否掉的路线。

**客户端 pin 什么：**
- Hub 仍然 pin Owner root。iOS 端仍然要在代理里设锚（Owner root 不在系统信任库里，对普通域名 ATS 还会拒绝），只是可以把 BasicX509 换成 SSL 策略、不用自己查主机名。
- Local API 要过 SSL 策略，证书就得加上 EKU 和 IP SAN。可是 IP 随 DHCP 变化，所以结果还是只能比对 SPKI。也就是说，**对 Local API 而言 (b) 纯属额外负担**。

**结论：** (b) 没有省掉任何客户端代码，也不提升安全性，却把"到期 → 续签 → 重启"这条失败链带了回来，并且让客户端从此跟着 Apple 的 WebPKI 政策走。Apple 没有说过 200/100/47 天这些新上限会不会延伸到私有根；Apple Root Program 政策 v2.0 约束的是加入根证书计划的公共 CA，对私有根只字未提〔文档〕。不推荐。

### 3.3 (c) 其他方式

- **c1 RFC 7250 裸公钥**：在架构上这本是最贴切的原语（ops 报告 §0 也提到了），但 Apple 平台的 TLS 不支持。我在 Apple 文档和论坛里都没找到相关支持；唯一提到 raw public key 的是 `NERelay.rawPublicKeys`（iOS 17），它只用于 Network Extension 的中继，不是通用 TLS。
- **c2 TLS-PSK**：
  - Network.framework 有 `sec_protocol_options_add_pre_shared_key`，但只支持 TLS 1.2，不支持 TLS 1.3 和 QUIC〔DTS 688508、715553、768961〕〔文档〕TN3213。
  - URLSession 不支持〔DTS 703234〕，iOS 26 的新 `NetworkConnection` API 目前也不支持〔DTS 807854〕。
  - 用了它还会失去 iOS 26 默认开启的抗量子 TLS 1.3〔文档〕WWDC25 314〔推断〕。
  - 它把信任落在每部手机和 Host 之间的共享秘密上，而 Hub 那一路是设备按 Owner root 校验的，套不上同一模型。不推荐。
- **c3 TLS exporter 通道绑定**：
  - Network.framework 提供 `sec_protocol_metadata_create_secret`（RFC 5705 exporter，见 SDK 头文件）。可以让 Host 用 Ed25519 身份密钥对 exporter 值签名，这样就不依赖证书了。
  - 但 URLSession 拿不到 exporter，只能自己处理 HTTP；admin 和 Hub ingress 也都要改。
  - Local API 的 SPKI 本来就由 Host Ed25519 签名，并且已经写进 PAKE 的确认上下文（`host_claim_pake.dart`），中间人换了 TLS 密钥就过不了 PAKE。再做一层 exporter 绑定没有新的保护对象。留作将来走远程中继时再考虑。
- **c4 用描述文件把 Owner root 装进系统信任**：〔源码〕用户信任存储里的证书确实不受 825 天检查约束。但用户得手动去"证书信任设置"里打开完全信任，而且 Safari 等整个系统都会因此信任这个根签出的任何名字。不可取。
- **c5 自带 TLS 栈**（例如 SwiftNIO SSL，基于 BoringSSL）：可以完全绕开 Apple 的信任评估，App Review 也不要求必须用系统 TLS〔DTS 818807〕。但要放弃系统 TLS 的维护和新特性，而且 App Store 的加密出口问题要如实答 "Yes"〔DTS 818807〕。对 HTTPS 没有必要；只有 BLE 那一路可能需要（§3.5）。
- **swift-certificates**（〔源码〕Apple 维护）不是另一种方案，而是 (a) 的一种实现方式：用它的 `Verifier` 加 `RFC5280Policy` 和 `ServerIdentityPolicy` 校验 Hub，再自己写一个小的 EKU 策略。好处是完全不依赖系统的 TLS 策略，同一份逻辑可以在 CI 上跑；代价是多引入几个依赖（swift-asn1、swift-crypto）。

### 3.4 推荐方案的 iOS 实现要点（只是设计，没有写代码）

**平台通道。** 用 Swift 实现和 Android 相同的 MethodChannel 协议 v1，包括：`request`/`cancel`；`tlsSpkiFingerprint` 与 `ownerRootCertificate` 二选一；`connectionAddress` 只允许用于 `.local` 的 Owner Authority；错误码和 `observedSpki` 细节字段都与 Android 一致，以便 `_adoptRotatedTlsIdentity` 能照常工作。

**两个评估器**，都写成纯函数，测试向量与 Android 共用：
- `OwnerRootEvaluator(chain, ownerRoot, expectedHubName, now)`：
  1. `SecTrustSetPolicies(SecPolicyCreateBasicX509())`、`SecTrustSetAnchorCertificates([ownerRoot])`、`SecTrustSetAnchorCertificatesOnly(true)`；
  2. 调 `SecTrustEvaluateWithError`，放在后台队列执行，或者用 `SecTrustEvaluateAsyncWithError`〔文档〕；
  3. 用 swift-certificates 解析叶证书，确认 SAN 里的 DNS 名集合恰好包含 `expectedHubName`（不区分大小写）、EKU 包含 serverAuth、`BasicConstraints` 不是 CA。

  `expectedHubName` 取自 descriptor，不取自 URL 主机，这样按 IP 后备时语义不变。
- `SpkiPinEvaluator(leaf, expectedPin)`：
  1. 依次调用 `SecTrustCopyCertificateChain`（取第 0 个）、`SecCertificateCopyKey`、`SecKeyCopyExternalRepresentation`；
  2. 用 CryptoKit 的 `P256.Signing.PublicKey(x963Representation:).derRepresentation` 得到 SPKI；
  3. 算 SHA-256，转成 base64url，用常量时间比较。

  不一致时把实际看到的 pin 返回给上层。如果要和 Android 的 `checkValidity()` 对齐，可以再以叶证书自身为锚跑一次 BasicX509，用它来检查有效期起止。

**传输层：**
- URLSession 使用 ephemeral 配置，每个请求一个会话，或者按"origin + 锚/pin"各建一个会话；
- `urlCache = nil`，不用 cookie；
- `connectionProxyDictionary = [:]`；
- 考虑开启 `waitsForConnectivity`，以便应对本地网络授权弹窗；
- 不跟随重定向，与 Android 一致。

**Hub 的地址：** 优先直接用 `.local` URL（iOS 会自己解析 mDNS）。解析失败时，用 `connectionAddress` 拼成 IP URL 再试，评估器仍然按 descriptor 给出的 `.local` 名核对证书。

**Info.plist：**
- 加上：`NSLocalNetworkUsageDescription`；`NSBonjourServices`，值为 `_eidolon-local-api._tcp`；`NSAppTransportSecurity` 下的 `NSAllowsLocalNetworking = YES`；`NSBluetoothAlwaysUsageDescription`。
- 不加：`NSAllowsArbitraryLoads`、`NSExceptionDomains`、组播 entitlement。

**不要在 iOS 上用 `dart:io` 的 `HttpClient` 走这两条通道**（§1.4 第 10 行）。

**复用：** 两个评估器同样可以用在 `NWConnection` 的 verify block、iOS 26 的 `TLS().certificateValidator`，以及 BLE 那一路选定的 TLS 实现上。

### 3.5 BLE 里的 TLS（随 iOS 客户端一起决定，不在本报告范围内）

- **现状**：Android 的 BLE 配网用 `SSLEngine` 在 GATT 上跑 TLS 1.2/1.3，pin 的是 Local API 的同一把公钥（`BleCommissioningManager.kt` 中的 `BleTlsClient`）。
- **iOS 上的一手信息：**
  - `sec_protocol_options` 不能用来定制底层传输〔DTS 685455，Matt Eaton〕。Apple 也不提供"在自定义传输上跑 TLS"的现成支持，需要第三方库。
  - Secure Transport 已经弃用，不支持 TLS 1.3，不应再用〔文档〕TN3151。
  - Apple 员工的论坛回答里没有找到"TLS over BLE"的说法。
- **可选路线：**
  1. 用 SwiftNIO SSL（BoringSSL）在 GATT 上跑 TLS，自定义校验回调里复用 `SpkiPinEvaluator`；
  2. 在本机回环 TCP 上开一个中继，让 Network.framework 的 TLS 连到中继，中继再把密文转发到 GATT〔推断〕，这条路没有 Apple 的一手说法；
  3. 让 iOS 的 BLE 只负责把 Host 引上 Wi‑Fi，Host 认领改走 Local API。

  无论选哪条，信任判定都还是 SPKI pin，与证书有效期无关。这一项随 iOS 客户端一起决定，不需要提前单独做。

## 4. 风险与待验证

- **还没在 iOS 上实测。** 动手实现之前，先在 iOS 17+ 和 iOS 26 的真机上按 §5 的清单跑一遍，重点是：
  - BasicX509 对 99 年证书放行、SSL 策略拒绝；
  - 局域网 IP 和 `.local` 在 `NSAllowsLocalNetworking` 下、代理自行校验能通过；
  - 本地网络授权弹窗与被拒的表现。
- **Apple 将来改策略的风险**：BasicX509 是通用 X.509 策略，Apple 没有说过会给它加 TLS 专用的限制，也没有说过会把公共 CA 的新上限延伸到私有根。如果想彻底不依赖系统策略，可以按 §3.3 用 swift-certificates 来实现 Hub 评估器。
- **自定义评估写错的风险**：测试至少覆盖以下情形：
  - 证书链终止于别的根；
  - 名字不符；
  - SAN 里只有 CN 或 URI；
  - 用 CA 证书当叶证书；
  - 缺少 EKU；
  - 已过期或尚未生效；
  - pin 不符，且错误里带回实际看到的 pin；
  - 证书链中多出一个中间证书；
  - 会话缓存不会让旧 pin 继续生效。
- **长期密钥泄露的影响**同 ops 报告 §3：靠重置 Owner 或 Host、重新配网和配对来处理。

## 5. 真机验证清单（有设备后执行）

目的是确认 macOS 上的实测结论在 iOS 上同样成立。下表"预期"一栏都是 macOS 26.5.2 上的实测结果；哪一项和预期不符，就按"不符时"一栏调整方案。

### 5.1 准备

- **设备**：
  - 一台 iOS 17 或更高版本的 iPhone，最好再有一台 iOS 26 的；
  - 一台装了 Xcode 的 Mac，与 iPhone 连同一个 Wi‑Fi；
  - iPhone 上关掉 VPN 和 Wi‑Fi 代理，T10 会单独测代理。
- **测试证书**：按附录第 1 步在 Mac 上生成 root、hub825、hub826、hub99、local 和 `local.spki`。T6 另需一张 99 年叶证书，SAN 为 `<Mac 局域网 IP>.nip.io`。
- **Mac 上的服务**：
  - 都要监听所有网卡。`openssl s_server -www -accept <端口> -cert <叶证书> -key <私钥>` 默认就是如此。
  - 端口分配：18443 放 hub99，18444 放 hub825，19002 放 local，18080 起一个普通 HTTP 服务（例如 `python3 -m http.server 18080`）。
  - 如果 macOS 防火墙拦截入站连接，先放行。
- **测试 App**：在 Xcode 里新建一个 iOS App，把 `probe/` 里的函数搬进去，改动如下：
  - `cert()` 改为从 App bundle 读 `.der` 文件，证书作为资源打进包里；
  - `CommandLine.arguments` 改为写死 Mac 的局域网 IP 和 `.local` 名；
  - 不要在主线程上调 `DispatchSemaphore.wait()`，改用 async/await；
  - 结果显示在界面上，或者用 `os_log` 输出。
- **Info.plist 准备两套**，测 ATS 的项目两套都要跑：
  - A 套：不写 `NSAppTransportSecurity`，即 ATS 默认设置；
  - B 套：`NSAllowsLocalNetworking = YES`，内容同 [`probe/ats-local.plist`](probe/ats-local.plist)。
  - 两套都要加 `NSLocalNetworkUsageDescription`，以及 `NSBonjourServices = [_eidolon-local-api._tcp]`。T9 需要去掉后者的时候会单独说明。
- **每次记录**：机型、iOS 版本、Xcode/SDK 版本。

### 5.2 测试项

| # | 测什么 | 怎么测 | 预期（macOS 实测） | 不符时 |
|---|---|---|---|---|
| T1 | 信任策略矩阵 | 跑 `trust_eval.swift` 的全部用例 | 与 §1.3 的表一致：SSL 策略拒 826 天和 99 年的证书（-67901）；BasicX509 全部通过 | BasicX509 拒 99 年证书：Hub 评估器改用 swift-certificates 的 `Verifier`（§1.4 第 11 行）。Local API 不受影响，因为它只比对 SPKI，不经过任何策略 |
| T2 | SPKI pin 的算法 | `trust_eval.swift` 的最后一段 | X9.63 公钥 65 字节，SPKI 91 字节，`matches-openssl=true` | 改用 swift-certificates 取出 `SubjectPublicKeyInfo` 的 DER，再算 SHA-256 |
| T3 | URLSession 按局域网 IP 访问 | `ats_local_names.swift` 里 LAN IPv4 的几行，A、B 两套各跑一次 | http 访问 18080 返回 200；Hub 的 99 年和 825 天证书用 BasicX509 返回 200；Local API 用 SPKI 返回 200 | 出现 -1022 或 -9802，说明 iOS 把私网 IP 也纳入了 ATS。这时 Local API 改走 Network.framework（T5），不加 IP 例外（§2.3） |
| T4 | URLSession 按 `.local` 名访问 | `ats_local_names.swift` 里 `.local` 的几行，A、B 两套 | 同 T3；第一次访问前会弹出本地网络授权 | 解析失败：先查 T7 的授权和 T9 的 Bonjour 键；Hub 改用 `connectionAddress` 后备 |
| T5 | Network.framework 的 verify block | `transport_test.swift` 里的三行 `nwGet`：连接地址改成 Mac 的局域网 IP，server name 保持 `eidolon-hub-test.local`。iOS 26 上可以再用 `TLS().certificateValidator` 重复一遍 | SPKI 和 BasicX509 两行进入 ready；SSL 策略那行报 -9808 | 如果 T1 通过而这里失败，记录错误，检查 verify block 的写法 |
| T6 | ATS 对照组 | `ats_fqdn.swift`，把 URL 改成 `<Mac 局域网 IP>.nip.io`，A、B 两套 | http 报 -1022，代理自行校验的 https 报 -9802。这说明测试 App 的 ATS 确实生效，可以拿来和 T3、T4 对照 | 如果通过了，说明 ATS 没生效，T3、T4 的结论不能算数，先查 Info.plist。如果是域名解析失败，可能是路由器的 DNS 重绑定保护拦了解析到私网 IP 的域名，换个网络再试 |
| T7 | 本地网络权限 | 新装 App 后第一次访问，分别选"允许"和"不允许"，然后到"设置"里把权限改回来 | 选允许：正常连接。选不允许：`NWConnection` 进入 `.waiting`，原因是 `localNetworkDenied`；改回允许后自动重试。URLSession 被拒时返回什么错误码，文档没写，要记下来 | 不论结果如何都要记录，用来设计授权文案和被拒后的提示（§2.1） |
| T8 | 后台时静默拒绝 | 卸载重装 App，在用户还没做过选择时，从后台发起一次局域网连接 | 不弹窗，直接失败 | 记录 |
| T9 | Bonjour 浏览 | 在 Mac 上用 `dns-sd -R test _eidolon-local-api._tcp local 9002` 注册服务，App 里用 `NWBrowser` 浏览；再去掉 `NSBonjourServices` 重装一次 | 有这个键时能发现服务；没有这个键时失败（WWDC20 演示里是 NoAuth，`kDNSServiceErr_PolicyDenied` 为 -65570） | 记录。同时确认：只解析 `.local` 主机名，是否也需要这个键（文档没写，§2.1） |
| T10 | 系统代理 | 在 iPhone 的 Wi‑Fi 设置里配一个指向不存在地址的 HTTP 代理，然后重跑 T3 | 设置了 `connectionProxyDictionary = [:]` 时直连成功 | 仍然走代理：局域网通道改走 Network.framework |
| T11 | pin 变化与会话缓存 | App 运行期间，把 19002 端口换成用另一把密钥签的证书，再发请求 | 新建的 ephemeral 会话按新证书校验，pin 不符而失败，并能拿到实际看到的 pin | 仍然成功：说明 TLS 会话被复用了，按 §2.4 在 pin 变化时作废会话 |
| T12 | （可选）`dart:io` | 如果那时 iOS 客户端仍用 Flutter：用 `HttpClient` 加 `SecurityContext.setTrustedCertificatesBytes(root)` 访问 18443 | 〔推断〕握手失败（CERTIFICATE_VERIFY_FAILED） | 通过：说明 §1.4 第 10 行的推断不成立，可以重新评估要不要沿用 `dart:io`（主机名仍要自己核对） |
| T13 | 连真实 Host 端到端 | 先用 `openssl x509 -noout -dates` 确认 Mac Host 的 `hub.crt` 已重签为 99 年。然后：Hub 用 `https://eidolon-hub-<id>.local:8443/`，锚是真实的 Owner root；Local API 用 `https://<Host IP>:9002/`，pin 取自 endpoint 文档 | TLS 握手通过，并拿到任意 HTTP 响应（401、404 也算，说明 TLS 那一层已经通过） | 对照 T3 到 T5 定位问题 |

### 5.3 怎么判定

- **T1 到 T6、T13 都符合预期**：可以按 §3.4 开始实现。
- **T3 或 T4 里局域网 IP 一项不符**：方案不变，只是 Local API 的传输改走 Network.framework。同时把这个结论补进设计文档 §3.6.1。
- **T1 不符**：方案不变，只是 Hub 评估器改用 swift-certificates。
- **T7 到 T9 的结果**：只影响本地网络授权的交互设计，不影响信任方案。

## 6. 后续

- 设计文档 §3.6.1（docs `设备与Body/设备生命周期状态机与恢复边.md`）已改写（2026-11-07）：原来的"已知决策点"改为"Apple 客户端（2026-11-07 已决）"，写明自行校验的做法、"端点保持为 `.local` 名或局域网 IP"这一前提，以及局域网 IP 一项还待真机确认。
- eidolon_ops `docs/reports/tls-pin-renewal-20261107/README.md` §3 第二条已改为"已决定"，并指向本报告。§4 的相应条目加了说明。
- iOS 客户端整体延后（2026-11-07 确认），BLE 配网也包括在内。启动 iOS 客户端时，先有设备按 §5 做真机验证，同时定下 BLE 里的 TLS 方案（§3.5）。

## 资料来源

**Apple 支持文档与政策**
- Requirements for trusted certificates in iOS 13 and macOS 10.15（103769）：https://support.apple.com/en-us/103769
- About upcoming limits on trusted certificates（102028，398 天）：https://support.apple.com/en-us/102028
- Apple Root Program Policy v2.0：https://github.com/apple/apple-root-program/blob/main/policy.md

**Apple 开发者文档**
- Performing Manual Server Trust Authentication：https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication
- Handling an Authentication Challenge：https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge
- Preventing Insecure Network Connections：https://developer.apple.com/documentation/security/preventing-insecure-network-connections
- NSAllowsLocalNetworking：https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- NSExceptionDomains：https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains
- NSPinnedDomains：https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nspinneddomains
- Identity Pinning（2021-01-14）：https://developer.apple.com/news/?id=g9ejcf8y
- NSURLRequest Reserved HTTP headers：https://developer.apple.com/documentation/foundation/nsurlrequest#Reserved-HTTP-headers
- `SecPolicyCreateSSL`、`SecPolicyCreateBasicX509`、`SecTrustSetAnchorCertificates`、`SecTrustSetAnchorCertificatesOnly`、`SecTrustEvaluateWithError`、`SecKeyCopyExternalRepresentation`：https://developer.apple.com/documentation/security
- CryptoKit `P256.Signing.PublicKey`：https://developer.apple.com/documentation/cryptokit/p256/signing/publickey
- `sec_protocol_options_set_verify_block`、`sec_protocol_options_set_tls_server_name`、`sec_protocol_options_add_pre_shared_key`：https://developer.apple.com/documentation/security
- Network `TLS.certificateValidator(_:)`（iOS 26）：https://developer.apple.com/documentation/network/tls
- NSLocalNetworkUsageDescription：https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription
- NSBonjourServices：https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- Multicast entitlement：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- iOS & iPadOS 17 Release Notes（101967030）：https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-17-release-notes

**技术说明**
- TN3179 Understanding local network privacy：https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- TN3151 Choosing the right networking API：https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- TN3213 Moving from Multipeer Connectivity to Network framework：https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- TN2232 HTTPS Server Trust Evaluation（已归档）：https://developer.apple.com/library/archive/technotes/tn2232/_index.html

**WWDC**
- WWDC20 10110 Support local network privacy in your app：https://developer.apple.com/videos/play/wwdc2020/10110/
- WWDC24 10123：https://developer.apple.com/videos/play/wwdc2024/10123/
- WWDC20 10111（TLS 1.3 默认开启）、WWDC25 314（抗量子 TLS）：https://developer.apple.com/videos/

**Apple 员工论坛回答**（https://developer.apple.com/forums/thread/<编号>）
- 773796（Quinn，2025-02，825 天适用于所有 CA，只由 TLS 策略施加）
- 703234（Quinn，2022-03，TLS For Accessory Developers）
- 67493（Quinn，TLS for App Developers，2025-11-21 修订；ATS 开启时默认评估必须通过）
- 720477、685558、70139、125174、130039（Matt Eaton）、765550
- 761130、750337、680572、798054、787830、672291（pin 与 SPKI）
- 685455（Matt Eaton，自定义传输）、818807（Quinn 与 Albert Pascual，TLS 实现与出口合规）、682940
- 688508、715553、768961、807854（TLS-PSK 与新 Swift API）
- 46413、114809（`.local` 解析）、747421、731217、66417、79662（ATS 与 IP）
- 关键几条（773796、703234、67493）的原文已在 2026-11-07 用浏览器逐字核对；其余由调研时抓取，引用前建议再看一眼原帖。

**Apple 开源代码**
- apple-oss-distributions/Security，tag Security-61901.120.67：`OSX/sec/Security/SecPolicy.c`（`SecPolicyCreateSSL_internal`、`set_ssl_validity_periods`、`SecPolicyCreateBasicX509`）、`trust/trustd/SecPolicyServer.c`（有效期上限与 `ServerAuthEKU` 检查）、`OSX/sec/Security/SecPolicyLeafCallbacks.c`（主机名检查）。https://github.com/apple-oss-distributions/Security
- apple/swift-certificates 1.21.1：https://github.com/apple/swift-certificates

**非 Apple 出处**
- dart-lang/sdk `runtime/bin/security_context_macos.cc`（commit `223176c250`）
- RFC 6066 §3（SNI 不能放 IP）、RFC 7250（裸公钥）、RFC 5705（TLS exporter）
- CA/B Forum Baseline Requirements（禁止为内部名称和保留 IP 签发证书）

**本仓库及兄弟仓库**
- 本仓库：`android/app/src/main/kotlin/live/eidolon/eidolon_client_mobile/PinnedHttpsClient.kt`、`PinnedSpkiTrustManager.kt`、`PinnedHttpsProtocol.kt`、`BleCommissioningManager.kt`、`LocalApiAnnouncement.kt`；`lib/src/features/host_setup/pinned_http_client.dart`、`lib/src/features/setup/host_claim_pake.dart`
- eidolon_ops：`src/eidolon_ops/owner_domain_assets.py`（`_host_tls`）、`src/eidolon_ops/lan_ingress.py`、`docs/reports/tls-pin-renewal-20261107/README.md`
- eidolon_admin：`server/eidolon_admin_server/bootstrap/tls_identity.py`
- 设计文档：`docs/设备与Body/设备生命周期状态机与恢复边.md` §3.6.1

## 附录：`probe/` 实测脚本

都是一次性实验，不属于产品代码。用到的证书在 scratchpad 里临时生成，没有放进本目录；生成方法见下。复现步骤（需要 macOS、Swift 和 openssl 3）：

1. 用 openssl 生成 P-256 的 Owner root（CA，99 年），由它签发 Hub 叶证书：SAN `DNS:eidolon-hub-test.local`，EKU 为 serverAuth（critical），有效期分别为 825 天、826 天和 36159 天。再生成一张 Local API 风格的自签证书（只有 `URI:urn:eidolon:host:…`，没有 EKU，36159 天），并把它的 SPKI SHA-256 以 base64url 写入 `local.spki`。各证书另存一份 DER（`<名字>.der`）。
2. `swiftc trust_eval.swift -o trust_eval && ./trust_eval <证书目录>`：对应 §1.3 的表。
3. 用 `openssl s_server -www` 分别在 18443（99 年 Hub 证书）、18444（825 天 Hub 证书，两个 ATS 脚本用）和 19002（Local API 证书）端口起服务，然后运行 `transport_test.swift`：测 URLSession 代理和 Network.framework 的 verify block。
4. `ats_local_names.swift` 和 `ats_fqdn.swift` 编译时用 `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker ats-*.plist` 嵌入 Info.plist，以启用 ATS，对应 §2.3 的表。`ats_fqdn.swift` 还需要一张 SAN 为 `127.0.0.1.nip.io` 的叶证书。`ats_local_names.swift` 的参数是 `<证书目录> <本机局域网 IP> <本机 .local 名>`，这时各服务要监听所有网卡，另需在 18080 端口起一个 HTTP 服务；测试只持续几秒。
