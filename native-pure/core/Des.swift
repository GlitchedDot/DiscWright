// Des.swift — mirror of des.js.
// DES via CommonCrypto one-shot CCCrypt, no padding (all payloads
// are block-aligned, exactly as in the JS). The two-key triple-DES
// EDE composition replicates atrac.js/des.js's exact operation
// sequence out of single-DES CCCrypt calls:
//   edeEncryptBlock(k16, b) = E_K1(D_K2(E_K1(b)))
//   edeDecryptBlock(k16, b) = D_K1(E_K2(D_K1(b)))
// Single-block calls use ECB mode explicitly; the CBC functions
// pass the IV and no ECB flag (CCCrypt's default mode is CBC).
import Foundation
import CommonCrypto

/// Shared error type for the whole core (JS `throw new Error(...)`).
enum DiscCoreError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let s): return s
    }
  }
}

private func desCrypt(operation: CCOperation, ecb: Bool, key: [UInt8],
                      iv: [UInt8]?, data: [UInt8]) throws -> [UInt8] {
  var out = [UInt8](repeating: 0, count: data.count)
  // Hoisted: reading out.count inside the withUnsafeMutableBytes
  // closure below is an overlapping access (the compiler's
  // exclusivity rule, hit on the first Mac build 2026-11-05).
  let outCount = out.count
  var outMoved = 0
  var options = CCOptions(0)
  if ecb { options = CCOptions(kCCOptionECBMode) }
  let status: CCCryptorStatus
  if let iv = iv {
    status = key.withUnsafeBytes { keyPtr in
      iv.withUnsafeBytes { ivPtr in
        data.withUnsafeBytes { inPtr in
          out.withUnsafeMutableBytes { outPtr in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmDES), options,
                    keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                    inPtr.baseAddress, data.count,
                    outPtr.baseAddress, outCount, &outMoved)
          }
        }
      }
    }
  } else {
    status = key.withUnsafeBytes { keyPtr in
      data.withUnsafeBytes { inPtr in
        out.withUnsafeMutableBytes { outPtr in
          CCCrypt(operation, CCAlgorithm(kCCAlgorithmDES), options,
                  keyPtr.baseAddress, key.count, nil,
                  inPtr.baseAddress, data.count,
                  outPtr.baseAddress, outCount, &outMoved)
        }
      }
    }
  }
  guard status == CCCryptorStatus(kCCSuccess), outMoved == data.count else {
    throw DiscCoreError.message("CCCrypt failed with status \(status)")
  }
  return out
}

/// desEncryptBlock(key8, block8) -> 8 bytes.
func desEncryptBlock(key8: [UInt8], block8: [UInt8]) throws -> [UInt8] {
  return try desCrypt(operation: CCOperation(kCCEncrypt), ecb: true,
                      key: key8, iv: nil, data: block8)
}

/// desDecryptBlock(key8, block8) -> 8 bytes.
func desDecryptBlock(key8: [UInt8], block8: [UInt8]) throws -> [UInt8] {
  return try desCrypt(operation: CCOperation(kCCDecrypt), ecb: true,
                      key: key8, iv: nil, data: block8)
}

/// edeEncryptBlock(key16, block8): E_K1 D_K2 E_K1, as in des.js.
func edeEncryptBlock(key16: [UInt8], block8: [UInt8]) throws -> [UInt8] {
  let k1 = Array(key16[0..<8])
  let k2 = Array(key16[8..<16])
  return try desEncryptBlock(key8: k1,
             block8: desDecryptBlock(key8: k2,
               block8: desEncryptBlock(key8: k1, block8: block8)))
}

/// edeDecryptBlock(key16, block8): D_K1 E_K2 D_K1, as in des.js.
func edeDecryptBlock(key16: [UInt8], block8: [UInt8]) throws -> [UInt8] {
  let k1 = Array(key16[0..<8])
  let k2 = Array(key16[8..<16])
  return try desDecryptBlock(key8: k1,
             block8: desEncryptBlock(key8: k2,
               block8: desDecryptBlock(key8: k1, block8: block8)))
}

/// desCbcEncrypt(key8, iv8, data); data length must be a multiple of 8.
func desCbcEncrypt(key8: [UInt8], iv8: [UInt8], data: [UInt8]) throws -> [UInt8] {
  if data.count % 8 != 0 {
    throw DiscCoreError.message("CBC data must be block-aligned")
  }
  return try desCrypt(operation: CCOperation(kCCEncrypt), ecb: false,
                      key: key8, iv: iv8, data: data)
}

/// desCbcDecrypt(key8, iv8, data); data length must be a multiple of 8.
func desCbcDecrypt(key8: [UInt8], iv8: [UInt8], data: [UInt8]) throws -> [UInt8] {
  if data.count % 8 != 0 {
    throw DiscCoreError.message("CBC data must be block-aligned")
  }
  return try desCrypt(operation: CCOperation(kCCDecrypt), ecb: false,
                      key: key8, iv: iv8, data: data)
}
