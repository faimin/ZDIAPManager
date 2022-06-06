//
//  IAPProtocols.h
//  Demo
//
//  Created by Zero.D.Saber on 2017/5/17.
//  Copyright © 2017年 zero.com. All rights reserved.
//

#import <Foundation/Foundation.h>
@class SKPaymentTransaction;

#ifndef IAPProtocols_h
#define IAPProtocols_h

NS_ASSUME_NONNULL_BEGIN
/// 本地化购买凭证协议
@protocol IAPStoreProtocol <NSObject>

/// 把购买凭证保存到keychain和DB中
+ (void)storeTransaction:(SKPaymentTransaction *)transaction
                 product:(SKProduct *_Nullable)product;

/// 购买成功并且也在服务端校验成功后，删除当前用户keychain中的商品信息
+ (BOOL)deleteProductFromKeychain:(NSString *)productId;

@end

NS_ASSUME_NONNULL_END

#endif /* IAPProtocols_h */
