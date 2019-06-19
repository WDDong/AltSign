//
//  ALTSigner.m
//  AltSign
//
//  Created by Riley Testut on 5/22/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "ALTSigner.h"
#import "ALTAppID.h"
#import "ALTTeam.h"
#import "ALTCertificate.h"
#import "ALTProvisioningProfile.h"

#import "NSFileManager+Apps.h"

#include "ldid.hpp"

#include <string>

#include <openssl/pkcs12.h>
#include <openssl/pem.h>

std::string CertificatesContent(ALTCertificate *altCertificate)
{
    NSURL *pemURL = [[NSBundle bundleForClass:ALTSigner.class] URLForResource:@"apple" withExtension:@"pem"];
    
    NSData *altCertificateP12Data = [altCertificate p12Data];
    
    BIO *inputP12Buffer = BIO_new(BIO_s_mem());
    BIO_write(inputP12Buffer, altCertificateP12Data.bytes, (int)altCertificateP12Data.length);
    
    auto inputP12 = d2i_PKCS12_bio(inputP12Buffer, NULL);
    
    // Extract key + certificate from .p12.
    EVP_PKEY *key;
    X509 *certificate;
    PKCS12_parse(inputP12, "", &key, &certificate, NULL);
    
    // Open .pem from file.
    auto pemFile = fopen(pemURL.path.fileSystemRepresentation, "r");
    
    // Extract certificates from .pem.
    auto *certificates = sk_X509_new(NULL);
    while (auto certificate = PEM_read_X509(pemFile, NULL, NULL, NULL))
    {
        sk_X509_push(certificates, certificate);
    }
    
    // Create new .p12 in memory with private key and certificate chain.
    char emptyString[] = "";
    auto outputP12 = PKCS12_create(emptyString, emptyString, key, certificate, certificates, 0, 0, 0, 0, 0);
    
    BIO *outputP12Buffer = BIO_new(BIO_s_mem());
    i2d_PKCS12_bio(outputP12Buffer, outputP12);
    
    char *buffer = NULL;
    NSUInteger size = BIO_get_mem_data(outputP12Buffer, &buffer);
    
    NSData *p12Data = [NSData dataWithBytes:buffer length:size];
    
    // Free .p12 structures
    PKCS12_free(inputP12);
    PKCS12_free(outputP12);
    
    BIO_free(inputP12Buffer);
    BIO_free(outputP12Buffer);
    
    // Close files
    fclose(pemFile);
    
    std::string output((const char *)p12Data.bytes, (size_t)p12Data.length);
    return output;
}

@implementation ALTSigner

+ (void)load
{
    OpenSSL_add_all_algorithms();
}

- (instancetype)initWithTeam:(ALTTeam *)team certificate:(ALTCertificate *)certificate
{
    self = [super init];
    if (self)
    {
        _team = team;
        _certificate = certificate;
    }
    
    return self;
}

- (NSProgress *)signAppAtURL:(NSURL *)appURL provisioningProfile:(ALTProvisioningProfile *)profile completionHandler:(void (^)(BOOL success, NSError *error))completionHandler
{
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:1];
    
    NSURL *ipaURL = nil;
    NSURL *appBundleURL = nil;
    
    void (^finish)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        if (ipaURL != nil)
        {
            NSError *removeError = nil;
            if (![[NSFileManager defaultManager] removeItemAtURL:[ipaURL URLByDeletingLastPathComponent] error:&removeError])
            {
                NSLog(@"Failed to clean up after resigning. %@", removeError);
            }
        }
        
        completionHandler(success, error);
    };
    
    __block NSError *error = nil;
    
    if ([appURL.pathExtension.lowercaseString isEqualToString:@"ipa"])
    {
        ipaURL = appURL;
        
        NSURL *outputDirectoryURL = [[appURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[[NSUUID UUID] UUIDString] isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:outputDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error])
        {
            finish(NO, error);
            return progress;
        }
        
        appBundleURL = [[NSFileManager defaultManager] unzipAppBundleAtURL:appURL toDirectory:outputDirectoryURL error:&error];
        if (appBundleURL == nil)
        {
            finish(NO, error);
            return progress;
        }
    }
    else
    {
        appBundleURL = appURL;
    }
    
    NSDirectoryEnumerator *countEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:appURL
                                                                  includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                                     options:0
                                                                                errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
                                                                                    if (error) {
                                                                                        NSLog(@"[Error] %@ (%@)", error, url);
                                                                                        return NO;
                                                                                    }
                                                                                    
                                                                                    return YES;
                                                                                }];
        
    NSInteger totalCount = 0;
    for (NSURL *__unused fileURL in countEnumerator)
    {
        NSNumber *isDirectory = nil;
        if (![fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil] || [isDirectory boolValue])
        {
            continue;
        }
        
        // Ignore CodeResources files.
        if ([[fileURL lastPathComponent] isEqualToString:@"CodeResources"])
        {
            continue;
        }
        
        totalCount++;
    }
    
    progress.totalUnitCount = totalCount;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *infoPlistURL = [appBundleURL URLByAppendingPathComponent:@"Info.plist"];
        
        NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfURL:infoPlistURL];
        infoPlist[(NSString *)kCFBundleIdentifierKey] = profile.bundleIdentifier;
        [infoPlist writeToURL:infoPlistURL atomically:YES];
        
        NSURL *profileURL = [appBundleURL URLByAppendingPathComponent:@"embedded.mobileprovision"];
        [profile.data writeToURL:profileURL atomically:YES];
        
        NSString *applicationIdentifier = [NSString stringWithFormat:@"%@.%@", self.team.identifier, profile.bundleIdentifier];
        NSString *keychainAccessGroup = [NSString stringWithFormat:@"%@.*", self.team.identifier];
        
        NSDictionary<NSString *, id> *entitlements = @{@"application-identifier": applicationIdentifier,
                                                       @"com.apple.developer.team-identifier": self.team.identifier,
                                                       @"keychain-access-groups": @[keychainAccessGroup],
                                                       @"get-task-allow": @YES,
                                                       };
        
        NSData *entitlementsData = [NSPropertyListSerialization dataWithPropertyList:entitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        if (entitlementsData == nil)
        {
            finish(NO, error);
            return;
        }
        
        NSString *entitlementsContents = [[NSString alloc] initWithData:entitlementsData encoding:NSUTF8StringEncoding];
        
        // Sign bundle
        ldid::DiskFolder appBundle(appBundleURL.fileSystemRepresentation);
        
        std::string key = CertificatesContent(self.certificate);
        std::string entitlementsString(entitlementsContents.UTF8String);
        
        ldid::Sign("", appBundle, key, "",
                   ldid::fun([&](const std::string &a, const std::string &b) -> std::string {
            return entitlementsString;
        }),
                   ldid::fun([&](const std::string &string) {
            progress.completedUnitCount += 1;
        }),
                   ldid::fun([&](const double signingProgress) {
            
        }));
        
        // Dispatch after to allow time to finish signing binary.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (ipaURL != nil)
            {
                NSURL *resignedIPAURL = [[NSFileManager defaultManager] zipAppBundleAtURL:appBundleURL error:&error];
                
                if (![[NSFileManager defaultManager] replaceItemAtURL:ipaURL withItemAtURL:resignedIPAURL backupItemName:nil options:0 resultingItemURL:nil error:&error])
                {
                    finish(NO, error);
                }
            }
            
            finish(YES, nil);
        });
    });

    return progress;
}

@end
