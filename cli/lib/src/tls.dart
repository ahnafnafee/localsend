import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';

/// A self-signed TLS identity for the receiver. The [fingerprint] is what
/// LocalSend peers pin (trust-on-first-use), so it is generated exactly the
/// way the app does (SHA-256 of the certificate DER, lowercase hex).
class TlsCredentials {
  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;

  const TlsCredentials({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprint,
  });
}

/// Generates a fresh RSA key + self-signed certificate, mirroring the app's
/// `generateSecurityContext` (app/lib/util/security_helper.dart) so the result
/// interoperates with real LocalSend clients.
TlsCredentials generateTlsCredentials() {
  final keyPair = CryptoUtils.generateRSAKeyPair();
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;

  const dn = {'CN': 'LocalSend User', 'O': '', 'OU': '', 'L': '', 'S': '', 'C': ''};
  final csr = X509Utils.generateRsaCsrPem(dn, privateKey, publicKey);
  final certificate = X509Utils.generateSelfSignedCertificate(keyPair.privateKey, csr, 365 * 10);

  return TlsCredentials(
    certificatePem: certificate,
    privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey),
    fingerprint: _hashOfCertificate(certificate),
  );
}

/// SHA-256 of the certificate's DER bytes, lowercase hex — the LocalSend
/// device fingerprint. Identical to `calculateHashOfCertificate` in the app.
String _hashOfCertificate(String certificate) {
  final pemBody = certificate
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('---'))
      .join();
  final der = base64Decode(pemBody);
  return CryptoUtils.getHash(Uint8List.fromList(der), algorithmName: 'SHA-256');
}
