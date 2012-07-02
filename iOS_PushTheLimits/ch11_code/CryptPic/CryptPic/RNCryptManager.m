//
//  RNCryptManager.m
//  CryptPic
//
//  Created by Rob Napier on 8/9/11.
//  Copyright (c) 2011 Rob Napier. All rights reserved.
//

#import "RNCryptManager.h"

// According to Apple documentaion, you can use a single buffer
// to do in-place encryption or decryption. This does not work
// in cases where you call CCCryptUpdate multiple times and you
// have padding enabled. radar://9930555
#define RNCRYPTMANAGER_USE_SAME_BUFFER 0

static const NSUInteger kMaxReadSize = 1024;

NSString * const
kRNCryptManagerErrorDomain = @"net.robnapier.RNCryptManager";

const CCAlgorithm kAlgorithm = kCCAlgorithmAES128;
const NSUInteger kAlgorithmKeySize = kCCKeySizeAES128;
const NSUInteger kAlgorithmBlockSize = kCCBlockSizeAES128;
const NSUInteger kAlgorithmIVSize = kCCBlockSizeAES128;
const NSUInteger kPBKDFSaltSize = 8;
const NSUInteger kPBKDFRounds = 10000;  // ~80ms on an iPhone 4

@interface NSOutputStream (Data)
- (BOOL)_CMwriteData:(NSData *)data error:(NSError **)error;
@end

@implementation NSOutputStream (Data)
- (BOOL)_CMwriteData:(NSData *)data error:(NSError **)error {
  // Writing 0 bytes will close the output stream.
  // This is an undocumented side-effect. radar://9930518
  if (data.length > 0) {
    NSInteger bytesWritten = [self write:data.bytes
                               maxLength:data.length];
    if ( bytesWritten != data.length) {
      if (error) {
        *error = [self streamError];
      }
      return NO;
    }
  }
  return YES;
}

@end
   
@interface NSInputStream (Data)
- (BOOL)_CMgetData:(NSData **)data
         maxLength:(NSUInteger)maxLength
             error:(NSError **)error;
@end

@implementation NSInputStream (Data)

- (BOOL)_CMgetData:(NSData **)data
         maxLength:(NSUInteger)maxLength
             error:(NSError **)error {

  NSMutableData *buffer = [NSMutableData dataWithLength:maxLength];
  if ([self read:buffer.mutableBytes maxLength:maxLength] < 0) {
    if (error) {
      *error = [self streamError];
      return NO;
    }
  }
  
  *data = buffer;
  return YES;
}

@end

@implementation RNCryptManager

+ (NSData *)randomDataOfLength:(size_t)length {
  NSMutableData *data = [NSMutableData dataWithLength:length];
  
  int result = SecRandomCopyBytes(kSecRandomDefault, 
                                  length,
                                  data.mutableBytes);
  NSAssert(result == 0, @"Unable to generate random bytes: %d",
           errno);
  
  return data;
}

+ (NSData *)AESKeyForPassword:(NSString *)password 
                         salt:(NSData *)salt {
  NSMutableData *
  derivedKey = [NSMutableData dataWithLength:kAlgorithmKeySize];
  
  int 
  result = CCKeyDerivationPBKDF(kCCPBKDF2,            // algorithm
                                password.UTF8String,  // password
                                password.length,  // passwordLength
                                salt.bytes,           // salt
                                salt.length,          // saltLen
                                kCCPRFHmacAlgSHA1,    // PRF
                                kPBKDFRounds,         // rounds
                                derivedKey.mutableBytes, // derivedKey
                                derivedKey.length); // derivedKeyLen
  
  // Do not log password here
  NSAssert(result == kCCSuccess,
           @"Unable to create AES key for password: %d", result);
  
  return derivedKey;
}

+ (BOOL)processResult:(CCCryptorStatus)result 
                bytes:(uint8_t*)bytes
               length:(size_t)length
                 toStream:(NSOutputStream *)outStream
                error:(NSError **)error {
  
  if (result != kCCSuccess) {
    if (error) {
      *error = [NSError errorWithDomain:kRNCryptManagerErrorDomain
                                   code:result
                               userInfo:nil];
    }
    // Don't assert here. It could just be a bad password
    NSLog(@"Could not process data: %d", result);
    return NO;
  }
  
  if (length > 0) {
    if ([outStream write:bytes maxLength:length] != length) {
      if (error) {
        *error = [outStream streamError];
      }
      return NO;
    }
  }
  return YES;
}

+ (BOOL)applyOperation:(CCOperation)operation
            fromStream:(NSInputStream *)inStream 
              toStream:(NSOutputStream *)outStream 
              password:(NSString *)password
                 error:(NSError **)error {
  
  NSAssert([inStream streamStatus] != NSStreamStatusNotOpen, 
           @"fromStream must be open");
  NSAssert([outStream streamStatus] != NSStreamStatusNotOpen, 
           @"toStream must be open");
  NSAssert([password length] > 0,
           @"Can't proceed with no password");
  
  // Generate the IV and salt, or read them from the stream
  NSData *iv;
  NSData *salt;
  switch (operation) {
    case kCCEncrypt:
      // Generate a random IV for this file.
      iv = [self randomDataOfLength:kAlgorithmIVSize];
      salt = [self randomDataOfLength:kPBKDFSaltSize];

      if (! [outStream _CMwriteData:iv error:error] ||
          ! [outStream _CMwriteData:salt error:error]) {
        return NO;
      }
      break;
    case kCCDecrypt:
      // Read the IV and salt from the encrypted file
      if (! [inStream _CMgetData:&iv
                       maxLength:kAlgorithmIVSize
                           error:error] ||
          ! [inStream _CMgetData:&salt
                       maxLength:kPBKDFSaltSize
                           error:error]) {
        return NO;
      }
      break;
    default:
      NSAssert(NO, @"Unknown operation: %d", operation);
      break;
  }
  
  NSData *key = [self AESKeyForPassword:password salt:salt];
  
  // Create the cryptor
  CCCryptorRef cryptor = NULL;
  CCCryptorStatus result;
  result = CCCryptorCreate(operation,             // operation
                           kAlgorithm,            // algorithim
                           kCCOptionPKCS7Padding, // options
                           key.bytes,             // key
                           key.length,            // keylength
                           iv.bytes,              // IV
                           &cryptor);             // OUT cryptorRef
  
  if (result != kCCSuccess || cryptor == NULL) {
    if (error) {
      *error = [NSError errorWithDomain:kRNCryptManagerErrorDomain
                                   code:result
                               userInfo:nil];
    }
    NSAssert(NO, @"Could not create cryptor: %d", result);
    return NO;
  }
  
  // Calculate the buffer size and create the buffers.
  // The MAX() check isn't really necessary, but is a safety in 
  // case RNCRYPTMANAGER_USE_SAME_BUFFER is enabled, since both
  // buffers will be the same. This just guarentees the the read
  // buffer will always be large enough, even during decryption.
  size_t 
  dstBufferSize = MAX(CCCryptorGetOutputLength(cryptor, // cryptor
                                      kMaxReadSize, // input length
                                               true), // final
                      kMaxReadSize);

  NSMutableData *
  dstData = [NSMutableData dataWithLength:dstBufferSize];
  
  NSMutableData *
#if RNCRYPTMANAGER_USE_SAME_BUFFER
  srcData = dstData;
#else
  // See explanation at top of file
  srcData = [NSMutableData dataWithLength:kMaxReadSize];
#endif
  
  uint8_t *srcBytes = srcData.mutableBytes;
  uint8_t *dstBytes = dstData.mutableBytes;
  
  // Read and write the data in blocks
  ssize_t srcLength;
  size_t dstLength = 0;
  
  while ((srcLength = [inStream read:srcBytes 
                           maxLength:kMaxReadSize]) > 0 ) {
    result = CCCryptorUpdate(cryptor,       // cryptor
                             srcBytes,      // dataIn
                             srcLength,     // dataInLength
                             dstBytes,      // dataOut
                             dstBufferSize, // dataOutAvailable
                             &dstLength);   // dataOutMoved
    
    if (![self processResult:result 
                       bytes:dstBytes
                      length:dstLength
                        toStream:outStream
                       error:error]) {
      CCCryptorRelease(cryptor);
      return NO;
    }
  }
  if (srcLength != 0) {
    if (error) {
      *error = [inStream streamError];
      return NO;
    }
  }

  // Write the final block
  result = CCCryptorFinal(cryptor,        // cryptor
                          dstBytes,       // dataOut
                          dstBufferSize,  // dataOutAvailable
                          &dstLength);    // dataOutMoved
  if (![self processResult:result 
                     bytes:dstBytes
                    length:dstLength
                      toStream:outStream
                     error:error]) {
    CCCryptorRelease(cryptor);
    return NO;
  }
  
  CCCryptorRelease(cryptor);
  return YES;
}

+ (BOOL)encryptFromStream:(NSInputStream *)fromStream 
                 toStream:(NSOutputStream *)toStream
                 password:(NSString *)password
                    error:(NSError **)error {
  return [self applyOperation:kCCEncrypt
                   fromStream:fromStream 
                     toStream:toStream 
                     password:password
                        error:error];
}

+ (BOOL)decryptFromStream:(NSInputStream *)fromStream
                 toStream:(NSOutputStream *)toStream
                 password:(NSString *)password
                    error:(NSError **)error {
  return [self applyOperation:kCCDecrypt
                   fromStream:fromStream 
                     toStream:toStream 
                     password:password
                        error:error];
}

+ (NSData *)encryptedDataForData:(NSData *)data
                        password:(NSString *)password
                              iv:(NSData **)iv
                            salt:(NSData **)salt
                           error:(NSError **)error {
  NSAssert(iv, @"IV must not be NULL");
  NSAssert(salt, @"salt must not be NULL");
  
  *iv = [self randomDataOfLength:kAlgorithmIVSize];
  *salt = [self randomDataOfLength:kPBKDFSaltSize];
  
  NSData *key = [self AESKeyForPassword:password salt:*salt];
  
  size_t outLength;
  NSMutableData *
  cipherData = [NSMutableData dataWithLength:data.length +
                kAlgorithmBlockSize];

  CCCryptorStatus
  result = CCCrypt(kCCEncrypt, // operation
                   kAlgorithm, // Algorithm
                   kCCOptionPKCS7Padding, // options
                   key.bytes, // key
                   key.length, // keylength
                   (*iv).bytes,// iv
                   data.bytes, // dataIn
                   data.length, // dataInLength,
                   cipherData.mutableBytes, // dataOut
                   cipherData.length, // dataOutAvailable
                   &outLength); // dataOutMoved

  if (result == kCCSuccess) {
    cipherData.length = outLength;
  }
  else {
    if (error) {
      *error = [NSError errorWithDomain:kRNCryptManagerErrorDomain
                                   code:result
                               userInfo:nil];
    }
    return nil;
  }
  
  return cipherData;
}

+ (NSData *)decryptedDataForData:(NSData *)data
                        password:(NSString *)password
                              iv:(NSData *)iv
                            salt:(NSData *)salt
                           error:(NSError **)error {

  NSData *key = [self AESKeyForPassword:password salt:salt];
  
  size_t outLength;
  NSMutableData *
  decryptedData = [NSMutableData dataWithLength:data.length];
  CCCryptorStatus
  result = CCCrypt(kCCDecrypt, // operation
                   kAlgorithm, // Algorithm
                   kCCOptionPKCS7Padding, // options
                   key.bytes, // key
                   key.length, // keylength
                   iv.bytes,// iv
                   data.bytes, // dataIn
                   data.length, // dataInLength,
                   decryptedData.mutableBytes, // dataOut
                   decryptedData.length, // dataOutAvailable
                   &outLength); // dataOutMoved
  
  if (result == kCCSuccess) {
    [decryptedData setLength:outLength];
  }
  else {
    if (result != kCCSuccess) {
      if (error) {
        *error = [NSError
                  errorWithDomain:kRNCryptManagerErrorDomain
                  code:result
                  userInfo:nil];
      }
      return nil;
    }
  }
  
  return decryptedData;
}


@end
