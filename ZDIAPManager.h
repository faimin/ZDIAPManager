//
//  ZDIAPManager.h
//  Demo
//
//  Created by Zero.D.Saber on 2017/5/15.
//  Copyright © 2017年 zero.com. All rights reserved.
//

/**
 购买工具类(单例),为了防止项目代码污染此类,数据存储放到其他类来处理
 */
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
@protocol IAPStoreProtocol;

#define TEXT_APPLE_LOST           @"设备越狱造成购买信息丢失"
#define TEXT_APPLE_NOT_ALLOW      @"由于设备原因不可购买"
#define TEXT_APPLE_ERROR          @"在iTunes Store购买失败"
#define TEXT_ITUNES_PRODUCT_ERROR @"暂时无法购买，请稍后再试"


#if (DEBUG && 1)
#define IAPLog(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#define IAPLog(...) ((void)0);
#endif

//===========================================================

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PurchaseSuccessNotification;

typedef NS_ENUM(NSInteger, IAPProductType) {
    IAPProductType_All = 0, ///< 全部类型的产品Id
    IAPProductType_Coin,    ///< 所有陌陌币类型的
    IAPProductType_VIP,     ///< 所有(S)VIP类型的
};

typedef void(^IAPProductsRequestResultBlock)(__kindof SKRequest * _Nullable request, SKProductsResponse * _Nullable response, NSError * _Nullable error);
typedef void(^IAPBuyProductsCompleteBlock)(SKPaymentTransaction *transaction);
typedef void(^IAPBuyProductsFailedBlock)(NSError * _Nullable error, NSString *customErrorMsg);



NS_CLASS_AVAILABLE_IOS(7_0)
@interface ZDIAPManager : NSObject

@property (nonatomic, assign) BOOL isInAppVerify;   ///< 是否在app中验证购买凭证,default is NO
@property (nonatomic, assign) BOOL isSandbox;       ///< 沙盒环境，default is NO
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, SKProduct *> *productDict;
@property (nonatomic, weak) id <IAPStoreProtocol> delegate;

/**
 单例方法(也可以直接调用alloc int / new)

 @return MDIAPManager实例
 */
+ (instancetype)shareIAPManager;

/**
 购买商品

 @param productIdentifiers 产品Id数组
 @param completeBlock 购买成功后的回调,@warning IAPManager会持有这个block，注意循环引用问题
 */
- (void)buyProductWithIdentifiers:(NSArray<NSString *> *)productIdentifiers
             requestProductResult:(IAPProductsRequestResultBlock)requestResultBlock
                         complete:(IAPBuyProductsCompleteBlock)completeBlock
                           failed:(IAPBuyProductsFailedBlock)faildBlock;

/**
 内购恢复
 */
- (void)restoreTransactions;

/**
 通过商品Id从内存中获取商品信息（如果已经缓存下来的话）
 
 @param productId 商品Id
 @return 商品
 */
- (SKProduct *)productForIdentifier:(NSString *)productId;

/// 格式化商品的价格
+ (NSString *)localizedPriceOfProduct:(SKProduct *)product;

/// 要购买的商品是否已经提前缓存到内存了
- (BOOL)existProductWithId:(NSString *)productId;

/// 买的是否是VIP
+ (BOOL)isVIPId:(NSString *)productId;
/// 买的是否是陌陌币
+ (BOOL)isCoinId:(NSString *)productId;

/// 当前设备是否允许内购(device whether allow pay)
+ (BOOL)allowPay;

/// 交易结束后一定要移除交易
+ (void)finishTransaction:(SKPaymentTransaction *)transaction;

/// 获取币种简写
+ (NSString *)currencyFromProduct:(SKProduct *)aProduct;

@end
NS_ASSUME_NONNULL_END

