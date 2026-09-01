#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

@interface MCUpdateAcceptanceTLSProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, assign) BOOL policyFailed;
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
    NSString *allowedHost = NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME"];
    return pin.length == CC_SHA256_DIGEST_LENGTH * 2 &&
        [allowedHost isEqualToString:@"localhost"] &&
        [NSURLProtocol propertyForKey:@"MCUpdateAcceptanceHandled" inRequest:request] == nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    NSString *allowedHost = NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME"];
    if (![self.request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        [self failPolicyWithReason:@"non-https"];
        return;
    }
    if (![self.request.URL.host.lowercaseString isEqualToString:allowedHost]) {
        [self failPolicyWithReason:@"non-local-host"];
        return;
    }
    NSMutableURLRequest *request = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"MCUpdateAcceptanceHandled" inRequest:request];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[];
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)failPolicyWithReason:(NSString *)reason
{
    if (self.policyFailed) {
        return;
    }
    self.policyFailed = YES;
    fprintf(stderr, "macchannel-update-acceptance state=tls-policy-reject reason=%s\n",
        reason.UTF8String);
    fflush(stderr);
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorUnsupportedURL userInfo:nil];
    [self.client URLProtocol:self didFailWithError:error];
}

- (void)stopLoading
{
    [self.task cancel];
    [self.session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    NSString *allowedHost = NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME"];
    SecCertificateRef certificate = trust == NULL ? NULL : SecTrustGetCertificateAtIndex(trust, 0);
    NSData *certificateData = certificate == NULL ? nil : CFBridgingRelease(SecCertificateCopyData(certificate));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certificateData.bytes, (CC_LONG)certificateData.length, digest);
    NSMutableString *actualPin = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [actualPin appendFormat:@"%02x", digest[index]];
    }
    NSString *expectedPin = [NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256"] lowercaseString];
    BOOL trustValid = NO;
    if (trust != NULL && certificate != NULL &&
        [challenge.protectionSpace.host.lowercaseString isEqualToString:allowedHost]) {
        SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)allowedHost);
        SecTrustSetPolicies(trust, policy);
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)certificate]);
        SecTrustSetAnchorCertificatesOnly(trust, true);
        trustValid = SecTrustEvaluateWithError(trust, NULL);
        CFRelease(policy);
    }
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        certificateData.length > 0 && trustValid && [actualPin isEqualToString:expectedPin]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        fprintf(stderr, "macchannel-update-acceptance state=tls-policy-reject reason=certificate-or-hostname\n");
        fflush(stderr);
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    completionHandler(nil);
    [self failPolicyWithReason:@"redirect"];
    [self.task cancel];
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
    if (self.policyFailed) {
        [self.session finishTasksAndInvalidate];
        return;
    } else if (error == nil) {
        [self.client URLProtocolDidFinishLoading:self];
    } else {
        [self.client URLProtocol:self didFailWithError:error];
    }
    [self.session finishTasksAndInvalidate];
}

@end
