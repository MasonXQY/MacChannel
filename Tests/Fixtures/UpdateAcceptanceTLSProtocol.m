#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

@interface MCUpdateAcceptanceTLSProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@end

@interface NSURLSessionConfiguration (MCUpdateAcceptanceTLS)
+ (NSURLSessionConfiguration *)mc_updateAcceptanceDefaultSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (MCUpdateAcceptanceTLS)

+ (void)load
{
    Method original = class_getClassMethod(self, @selector(defaultSessionConfiguration));
    Method replacement = class_getClassMethod(self, @selector(mc_updateAcceptanceDefaultSessionConfiguration));
    method_exchangeImplementations(original, replacement);
}

+ (NSURLSessionConfiguration *)mc_updateAcceptanceDefaultSessionConfiguration
{
    NSURLSessionConfiguration *configuration = [self mc_updateAcceptanceDefaultSessionConfiguration];
    NSArray<Class> *existingClasses = configuration.protocolClasses ?: @[];
    configuration.protocolClasses = [@[MCUpdateAcceptanceTLSProtocol.class]
        arrayByAddingObjectsFromArray:existingClasses];
    return configuration;
}

@end

@implementation MCUpdateAcceptanceTLSProtocol

+ (void)load
{
    [NSURLProtocol registerClass:self];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSString *pin = NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256"];
    return pin.length == CC_SHA256_DIGEST_LENGTH * 2 &&
        [request.URL.scheme.lowercaseString isEqualToString:@"https"] &&
        [request.URL.host.lowercaseString isEqualToString:@"localhost"] &&
        [NSURLProtocol propertyForKey:@"MCUpdateAcceptanceHandled" inRequest:request] == nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    NSMutableURLRequest *request = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"MCUpdateAcceptanceHandled" inRequest:request];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[];
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)stopLoading
{
    [self.task cancel];
    [self.session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    SecCertificateRef certificate = trust == NULL ? NULL : SecTrustGetCertificateAtIndex(trust, 0);
    NSData *certificateData = certificate == NULL ? nil : CFBridgingRelease(SecCertificateCopyData(certificate));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certificateData.bytes, (CC_LONG)certificateData.length, digest);
    NSMutableString *actualPin = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [actualPin appendFormat:@"%02x", digest[index]];
    }
    NSString *expectedPin = [NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256"] lowercaseString];
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        certificateData.length > 0 && [actualPin isEqualToString:expectedPin]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error == nil) {
        [self.client URLProtocolDidFinishLoading:self];
    } else {
        [self.client URLProtocol:self didFailWithError:error];
    }
    [self.session finishTasksAndInvalidate];
}

@end
