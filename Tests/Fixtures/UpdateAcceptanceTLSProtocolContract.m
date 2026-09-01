#import <Foundation/Foundation.h>

@interface MCUpdateAcceptanceTLSProtocol : NSURLProtocol
@end

@interface MCTLSProtocolClient : NSObject <NSURLProtocolClient>
@property(nonatomic, strong) NSError *error;
@end

@implementation MCTLSProtocolClient
- (void)URLProtocol:(NSURLProtocol *)protocol wasRedirectedToRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse {}
- (void)URLProtocol:(NSURLProtocol *)protocol cachedResponseIsValid:(NSCachedURLResponse *)cachedResponse {}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveResponse:(NSURLResponse *)response cacheStoragePolicy:(NSURLCacheStoragePolicy)policy {}
- (void)URLProtocol:(NSURLProtocol *)protocol didLoadData:(NSData *)data {}
- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol {}
- (void)URLProtocol:(NSURLProtocol *)protocol didFailWithError:(NSError *)error
{
    self.error = error;
}
@end

static void requireInvalidConfigurationFailure(NSString *pin, NSString *hostname)
{
    if (pin == nil) {
        unsetenv("MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256");
    } else {
        setenv("MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256", pin.UTF8String, 1);
    }
    if (hostname == nil) {
        unsetenv("MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME");
    } else {
        setenv("MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME", hostname.UTF8String, 1);
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://localhost:443/appcast.xml"]];
    if (![MCUpdateAcceptanceTLSProtocol canInitWithRequest:request]) {
        fprintf(stderr, "tls contract failed to intercept invalid configuration\n");
        exit(1);
    }
    MCTLSProtocolClient *client = [MCTLSProtocolClient new];
    MCUpdateAcceptanceTLSProtocol *protocol =
        [[MCUpdateAcceptanceTLSProtocol alloc] initWithRequest:request
            cachedResponse:nil client:client];
    [protocol startLoading];
    if (![client.error.domain isEqualToString:NSURLErrorDomain] ||
        client.error.code != NSURLErrorUnsupportedURL) {
        fprintf(stderr, "tls contract did not fail invalid configuration as unsupported URL\n");
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        requireInvalidConfigurationFailure(nil, @"localhost");
        requireInvalidConfigurationFailure(@"short", @"localhost");
        requireInvalidConfigurationFailure(@"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", @"localhost");
        requireInvalidConfigurationFailure(@"0000000000000000000000000000000000000000000000000000000000000000", nil);
        requireInvalidConfigurationFailure(@"0000000000000000000000000000000000000000000000000000000000000000", @"external.invalid");
    }
    printf("tls protocol contract PASS\n");
    return 0;
}
