//
//  ZDIAPManager.m
//  Demo
//
//  Created by Zero.D.Saber on 2017/5/15.
//  Copyright © 2017年 zero.com. All rights reserved.
//

#import "ZDIAPManager.h"
#import <objc/runtime.h>
#import "IAPProtocols.h"

#if !__has_feature(objc_arc)
#error "MDIAPManager.m must be compiled with the (-fobjc-arc) flag"
#endif

#define IAP_HandleRenewFee (0) ///< 是否处理续费交易

NSString * const PurchaseSuccessNotification = @"PurchaseSuccessNotification";

static NSUInteger const kMaxRetryCount = 3; ///< 请求商品失败后的最大重试次数
static NSString * const kDomain = @"IAPDomain";
static NSString * const kSandboxVerify = @"https://sandbox.itunes.apple.com/verifyReceipt";
static NSString * const kServerVerify = @"https://buy.itunes.apple.com/verifyReceipt";

@interface ZDIAPManager () <SKProductsRequestDelegate, SKPaymentTransactionObserver>
{
@private
    
}
@property (nonatomic, copy  ) IAPProductsRequestResultBlock requestProductsResultBlock;
@property (nonatomic, copy  ) IAPBuyProductsCompleteBlock buyProductsCompleteBlock;
@property (nonatomic, copy  ) IAPBuyProductsFailedBlock buyProductsFailedBlock;

@property (nonatomic, strong) NSMutableSet *purchasedProductSet;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SKProduct *> *allProductDict;
@property (nonatomic, strong) SKProductsRequest *productRequest;
@property (nonatomic, assign) NSUInteger retryCount;
@property (nonatomic, copy  ) NSString *buyingProductId; ///< 正在购买的商品Id
@property (nonatomic, assign) BOOL isBuyWhenRequestEnd;  ///< 请求完商品信息后直接把商品加入购买队列里
@end

@implementation ZDIAPManager

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __block id observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [ZDIAPManager shareIAPManager];
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
        }];
    });
}

#pragma mark - LifeCycle

- (void)dealloc {
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
}

- (instancetype)init {
    if (self = [super init]) {
        // 监听购买队列
        if (!objc_getAssociatedObject(self, _cmd)) {
            [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
            objc_setAssociatedObject(self, _cmd, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return self;
}

#pragma mark - Singleton

+ (instancetype)shareIAPManager {
    static ZDIAPManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[super allocWithZone:NULL] init];
    });
    return manager;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    return [self shareIAPManager];
}

#pragma mark - Public Method

- (void)requestProduct:(NSString *)productId
                result:(IAPProductsRequestResultBlock)requestBlock {
    NSCParameterAssert(productId);
    if (!productId || productId.length == 0) return;
    
    self.requestProductsResultBlock = requestBlock;
    [self requestProductWithIdentifiers:[NSSet setWithObject:productId]];
}

- (void)requestAllProducts:(IAPProductType)productType
             requestResult:(IAPProductsRequestResultBlock)requestResultBlock{
    NSSet *productSet = nil;
    switch (productType) {
        case IAPProductType_All:
            productSet = [self.class allProductIdentifiers];
            break;
        case IAPProductType_Coin:
            productSet = [self.class coinProductIdentifiers];
            break;
        case IAPProductType_VIP:
            productSet = [self.class vipProductIdentifiers];
            break;
        default:
            break;
    }
    
    self.requestProductsResultBlock = requestResultBlock;
    
    [self requestProductWithIdentifiers:productSet];
}

- (void)buyProductWithIdentifier:(NSString *)productId
            requestProductResult:(IAPProductsRequestResultBlock)requestResultBlock
                        complete:(IAPBuyProductsCompleteBlock)completeBlock
                          failed:(IAPBuyProductsFailedBlock)failedBlock {
    NSCParameterAssert(productId);
    if (!productId || productId.length == 0) return;
    
    self.buyingProductId = productId;
    [self buyProductWithIdentifiers:@[productId] requestProductResult:requestResultBlock complete:completeBlock failed:failedBlock];
}

/// 有缓存的话直接购买，否则是先请求商品信息再购买
- (void)buyProductWithIdentifiers:(NSArray<NSString *> *)productIdentifiers
             requestProductResult:(IAPProductsRequestResultBlock)requestResultBlock
                         complete:(IAPBuyProductsCompleteBlock)completeBlock
                           failed:(IAPBuyProductsFailedBlock)failedBlock {
    
    NSCParameterAssert([productIdentifiers isKindOfClass:[NSArray class]] && productIdentifiers);
    if (productIdentifiers.count <= 0) return;
    
    if (![ZDIAPManager allowPay]) {
        NSError *error = [self errorWithMsg:@"当前用户禁用了内购功能"];
        if (requestResultBlock) requestResultBlock(nil, nil, error);
        return;
    }
    
    // 重置重试次数
    [self resetRetryCount];
    
    self.requestProductsResultBlock = requestResultBlock;
    self.buyProductsCompleteBlock = completeBlock;
    self.buyProductsFailedBlock = failedBlock;
    
    NSArray *allKeys = self.allProductDict.allKeys;
    // 有商品缓存
    if (allKeys.count > 0) {
        NSMutableSet *allKeysSet = [NSMutableSet setWithArray:allKeys];
        NSMutableSet *productIdsSet = [NSMutableSet setWithArray:productIdentifiers];
        NSSet *productIdsSet_copy = [productIdsSet copy];
        BOOL isSub = [productIdsSet isSubsetOfSet:allKeysSet];
        
        // 传进来的Ids有的不在有效队列（allProductDict）中
        if (!isSub) {
            [productIdsSet minusSet:allKeysSet];//从前者集合中删除后者集合中**存在**的元素
            if (productIdsSet.count > 0) { //说明传进来的id中，有的id不在allProductDict中
                IAPLog(@"error：传进来的id包含无效的---> 无效的ids：%@，\n全部的ProductIds：%@", productIdsSet, productIdentifiers);
                
                // productIdsSet是处理过的集合,如果只请求缺失的id，后面处理起来会有点混乱，所以直接请求传进来的ids
                self.isBuyWhenRequestEnd = YES;
                [self requestProductWithIdentifiers:productIdsSet_copy];
            }
            //[productIdsSet intersectSet:allKeysSet]; //取二者的交集,从前者中删除在后者中**不存在**的元素
        }
        // 传进来的Ids都在已请求下来的商品队列（allProductDict）中
        else {
            self.isBuyWhenRequestEnd = NO;
            [self directBuyProducts:productIdentifiers];
        }
    }
    // 无缓存商品,直接请求
    else {
        self.isBuyWhenRequestEnd = YES;
        NSSet *productIdSet = [NSSet setWithArray:productIdentifiers];
        [self requestProductWithIdentifiers:productIdSet];
    }
}

/// 恢复内购
- (void)restoreTransactions {
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

/// 通过商品Id获取商品
- (SKProduct *)productForIdentifier:(NSString *)productId {
    NSCParameterAssert(productId);
    if (!productId) return nil;
    
    return self.allProductDict[productId];
}

+ (NSString *)localizedPriceOfProduct:(SKProduct *)product {
    if (!product) return nil;
    
    NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
    numberFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
    numberFormatter.locale = product.priceLocale;
    NSString *formattedString = [numberFormatter stringFromNumber:product.price];
    return formattedString;
}

+ (BOOL)isVIPId:(NSString *)productId {
    NSCParameterAssert(productId);
    BOOL isVIPId = [[self vipProductIdentifiers] containsObject:productId];
    return isVIPId;
}

+ (BOOL)isCoinId:(NSString *)productId {
    NSCParameterAssert(productId);
    BOOL isCoinId = [[self coinProductIdentifiers] containsObject:productId];
    return isCoinId;
}

- (BOOL)existProductWithId:(NSString *)productId {
    NSCAssert(productId, @"产品Id不能为nil");
    if (!productId || !self.allProductDict) return NO;
    return [self.allProductDict.allKeys containsObject:productId];
}

+ (BOOL)allowPay {
    BOOL allowPay = [SKPaymentQueue canMakePayments];
    if (!allowPay) IAPLog(@"该用户禁用了内购功能");
    return allowPay;
}

+ (void)finishTransaction:(SKPaymentTransaction *)transaction {
    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
}

+ (NSString *)currencyFromProduct:(SKProduct *)aProduct {
    if (!aProduct) return nil;
    /*
     NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
     [numberFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
     [numberFormatter setNumberStyle:NSNumberFormatterCurrencyStyle];
     [numberFormatter setLocale:aProduct.priceLocale];
     NSString *formattedPrice = [numberFormatter stringFromNumber:aProduct.price];
     IAPLog(@"货币前缀+价格：%@", formattedPrice); //￥6
     */
    NSString *currencyInfoString = aProduct.priceLocale.localeIdentifier;
    NSString *country = [aProduct.priceLocale objectForKey:NSLocaleCountryCode];
    NSString *language = [aProduct.priceLocale objectForKey:NSLocaleLanguageCode];
    NSString *currency = [aProduct.priceLocale objectForKey:NSLocaleCurrencyCode];
    IAPLog(@"完整信息：%@, 国家：%@, 语言：%@, 币种：%@", currencyInfoString, country, language, currency);//总信息：en_BT@currency=USD, 国家：CN, 语言：zh, 币种：CNY
    return currency;
}

#pragma mark - Private Method

/// 不用商品信息，直接用以前请求下来的结果
- (void)directBuyProducts:(NSArray<NSString *> *)productIds {
    [self addPayRequestToQueueWithProductIds:productIds];
}

/// 失败后再尝试3次请求(既然请求，那就把全部数据请求下来得了)
- (void)retryRequestProductWithRequest:(SKRequest *)request response:(SKProductsResponse *)response error:(NSError *)error {
    if (self.retryCount < kMaxRetryCount) {
        self.retryCount++;
        [self requestAllProductData];
    }
    else {
        IAPLog(@"error：重试3次后依然无法获取到产品信息");
        NSError *requestError = error ?: [self errorWithMsg:TEXT_ITUNES_PRODUCT_ERROR];
        if (self.requestProductsResultBlock) self.requestProductsResultBlock(request, response, requestError);
    }
}

- (void)requestAllProductData {
    [self requestProductWithIdentifiers:[self.class allProductIdentifiers]];
}

/// 每次有新的请求商品信息时、购买成功后（即移除trasaction时）、重试成功后，
/// 都要记得重置retryCount，因为这个类是单例
- (void)resetRetryCount {
    self.retryCount = 0;
}

- (NSData *)receipData:(SKPaymentTransaction *)transaction {
    NSData *receiptData = nil;
    if (NSFoundationVersionNumber >= NSFoundationVersionNumber_iOS_7_0) {
        NSURL *url = [[NSBundle mainBundle] appStoreReceiptURL];
        receiptData = [NSData dataWithContentsOfURL:url];
    }
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        receiptData = transaction.transactionReceipt;
#pragma clang diagnostic pop
    }
    
    return receiptData;
}

- (NSError *)errorWithMsg:(NSString *)errorMsg {
    return [self errorWithDomain:nil code:0 errorMsg:errorMsg];
}

- (NSError *)errorWithDomain:(NSString *)domain code:(NSInteger)code errorMsg:(NSString *)errorMsg {
    /*NSCocoaErrorDomain*/
    NSError *error = [NSError errorWithDomain:(domain ?: kDomain)
                                         code:(code ?: -100)
                                     userInfo:@{ NSLocalizedDescriptionKey : (errorMsg ?: @"") }];
    return error;
}

#pragma mark - Common Method

- (void)requestProductWithIdentifiers:(NSSet *)productIdSet {
    NSCParameterAssert(productIdSet && productIdSet.count > 0);
    if (!productIdSet || productIdSet.count == 0) return;
    
    // 如果上一个请求还未完成，取消掉
    if (self.productRequest) {
        self.productRequest.delegate = nil;
        [self.productRequest cancel];
        self.productRequest = nil;
    }
    
    self.productRequest = ({
        SKProductsRequest *productRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:productIdSet];
        productRequest.delegate = self;
        productRequest;
    });
    [self.productRequest start];
}

#pragma mark - SKProductsRequestDelegate

/// 使用productId所查询到的商品信息SKPayment
- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    
    NSArray *products = response.products;
    if (products.count == 0) {
        IAPLog(@"无法获取产品信息，购买失败");
        [self retryRequestProductWithRequest:request response:response error:nil];
        return;
    }
    else {
        [self resetRetryCount];
    }
    
#if DEBUG
    for (NSString *invalidProductIdentifier in response.invalidProductIdentifiers) {
        IAPLog(@"无效的产品Id：%@", invalidProductIdentifier);
    }
    IAPLog(@"产品付费数量：%zd", products.count);
#endif
    
    if (!self.allProductDict) {
        self.allProductDict = [[NSMutableDictionary alloc] initWithCapacity:products.count];
    }
    
    for (SKProduct *product in products) {
        IAPLog(@"------开始打印 product info:------");
        IAPLog(@"SKProduct 描述信息：%@", [product description]);
        IAPLog(@"产品标题：%@", product.localizedTitle);
        IAPLog(@"产品描述信息：%@", product.localizedDescription);
        IAPLog(@"价格：%@", product.price);
        IAPLog(@"币种信息：%@", product.priceLocale.localeIdentifier);
        IAPLog(@"ProductId：%@", product.productIdentifier);
        
        // 把商品添加到字典
        [self.allProductDict setValue:product forKey:product.productIdentifier];
    }
    
    if (_isBuyWhenRequestEnd) {
        [self addPayRequestToQueueWithProductIds:self.allProductDict.allKeys];
        _isBuyWhenRequestEnd = NO;
    }
    
    // block回调
    if (self.requestProductsResultBlock) self.requestProductsResultBlock(request, response, nil);
    
    // 请求完成后把请求置为nil
    self.productRequest = nil;
}

/// 把产品加入购买队列（当用户点击系统弹框的购买按钮时会从队列里拿出产品，然后依次购买）
- (void)addPayRequestToQueueWithProductIds:(NSArray<NSString *> *)productIds {
    NSSet *productIdSet = [NSSet setWithArray:productIds];
    
    IAPLog(@"-------- %zd个商品加入到购买队列--------", productIdSet.count);
    for (NSString *productId in productIdSet) {
        SKProduct *product = self.allProductDict[productId];
        if (product) {
            SKPayment *payment = [SKPayment paymentWithProduct:product];
            [[SKPaymentQueue defaultQueue] addPayment:payment];
        }
    }
}

#pragma mark - SKRequestDelegate

- (void)requestDidFinish:(SKRequest *)request {
    IAPLog(@"产品信息请求结束");
}

/// 请求失败
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    IAPLog(@"产品信息请求失败：%@", error.localizedDescription);
    [self retryRequestProductWithRequest:request response:nil error:error];
}

#pragma mark - SKPaymentTransactionObserver

/// 当用户的购买操作有结果(先添加进列表,再回调一次告知是否交易成功)时，就会触发下面的回调函数
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    IAPLog(@"--------- 购买状态更新 ------------");
    
    if (transactions.count == 0) {
        if (self.buyProductsFailedBlock) self.buyProductsFailedBlock(nil, TEXT_APPLE_LOST);
        return;
    }
    
    IAPLog(@"交易队列中的商品个数：%zd", transactions.count);
    
    for (SKPaymentTransaction *transaction in transactions) {
        @autoreleasepool {
            IAPLog(@"\n商品Id：%@", transaction.payment.productIdentifier);
            IAPLog(@"交易时间：%@", transaction.transactionDate);
            IAPLog(@"交易订单号：%@\n", transaction.transactionIdentifier);
            
#if IAP_HandleRenewFee
            // productId存在,但是productId与商品Id不同时跳过;
            // productId为nil时一般为订阅续费的情况
            if (self.buyingProductId) {
                // 有时会出现返回好多个交易信息的情况，在此过滤一下
                BOOL isEqualProductId = [transaction.payment.productIdentifier isEqualToString:self.buyingProductId];
                BOOL isEqualOriginProductId = (transaction.transactionState == SKPaymentTransactionStateRestored && [transaction.originalTransaction.payment.productIdentifier isEqualToString:self.buyingProductId]);
                if (!isEqualProductId && !isEqualOriginProductId) {
                    continue;
                }
            }
#else
            NSString *transactionId = transaction.transactionIdentifier;
            BOOL isEqualProductId = [transaction.payment.productIdentifier isEqualToString:self.buyingProductId];
            if (self.buyingProductId.length > 0 && !isEqualProductId && transactionId.length > 0) {
                
            }
            /*
             BOOL isEqualOriginProductId = (transaction.transactionState == SKPaymentTransactionStateRestored && [transaction.originalTransaction.payment.productIdentifier isEqualToString:self.buyingProductId]);
             // 都不相同时直接pass掉
             if (!isEqualProductId && !isEqualOriginProductId) {
                continue;
             }
             */
            
#endif
            
#if DEBUG
            // debug模式下会返回许多的续订交易,为了不影响测试，需要filter一下
            if (!isEqualProductId) {
                continue;
            }
#endif
            
            switch (transaction.transactionState) {
                case SKPaymentTransactionStatePurchasing:   // 商品添加进列表(购买中...)
                {
                    IAPLog(@"----- 正在购买,弹出购买确认框 --------");
                }
                    break;
                    
                case SKPaymentTransactionStatePurchased:    // 交易成功
                {
                    [self completeTransaction:transaction];
                    IAPLog(@"----- APP与苹果交易成功 --------");
                }
                    break;
                    
                case SKPaymentTransactionStateFailed:       // 交易失败
                {
                    [self failedTransaction:transaction];
                    IAPLog(@"------ APP与苹果交易失败 -------");
                }
                    break;
                    
                case SKPaymentTransactionStateRestored:     // 已经购买过该商品
                {
                    [self restoreTransaction:transaction];
                    IAPLog(@"----- 已经购买过该商品 --------");
                }
                    break;
                    
                default:
                    break;
            }
        }
    }
}

// Sent when transactions are removed from the queue (via finishTransaction:)
- (void)paymentQueue:(SKPaymentQueue *)queue removedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    IAPLog(@"----- 从购买队列中移除商品 --------");
    [self resetRetryCount];
}

// Sent when an error is encountered while adding transactions from the user's purchase history back to the queue.
- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    IAPLog(@"----- 恢复内购失败 --------%@", error);
}

// Sent when all transactions from the user's purchase history have successfully been added back to the queue.
- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    IAPLog(@"----- 恢复内购成功 --------");
    
    for (SKPaymentTransaction *transaction in queue.transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStateRestored: // 恢复内购
            {
                [self completeTransaction:transaction];
            }
                break;
                
            default:
                break;
        }
    }
}

// Sent when the download state has changed.
- (void)paymentQueue:(SKPaymentQueue *)queue updatedDownloads:(NSArray<SKDownload *> *)downloads {
    IAPLog(@"%s", __PRETTY_FUNCTION__);
}

#pragma mark - 交易最终结果
/// 交易成功
- (void)completeTransaction:(SKPaymentTransaction *)transaction {
    // 如果是自动续费的订单originalTransaction会有内容,而且订阅类的商品交易信息每次都是相同的(里面的时间不同),所以这里还是用新的transition吧
    if (transaction.transactionState == SKPaymentTransactionStateRestored && transaction.originalTransaction) {
        [self completeTransaction:transaction isWillRestore:YES];
    }
    //普通购买，以及第一次购买自动订阅
    else {
        [self completeTransaction:transaction isWillRestore:NO];
    }
}

/// 后面的参数表示是否已经购买过该商品，并恢复上一次的交易
- (void)completeTransaction:(SKPaymentTransaction *)transaction isWillRestore:(BOOL)isOldTransaction {
    // 商品Id
    NSString *productIdentifier = nil;
    if (isOldTransaction) {
        productIdentifier = transaction.originalTransaction.payment.productIdentifier;
    }
    else {
        productIdentifier = transaction.payment.productIdentifier;
    }
    
    NSCParameterAssert(productIdentifier.length > 0);
    if (productIdentifier.length <= 0) return;
    
    //MARK:校验之前保存交易凭证,防止在与服务器交互时出现问题
    // 在这里获取Product主要是为了通过它来拿到货币种类信息
    SKProduct *product = (productIdentifier.length > 0) ? self.allProductDict[productIdentifier] : nil;
    [self recordTransaction:transaction product:product];
    
#if IAP_HandleRenewFee
    // 续费VIP订单
    if (!self.buyingProductId) {
        [[NSNotificationCenter defaultCenter] postNotificationName:IAPRenewFeeTransactionNotification object:nil];
    }
#endif
    
    //购买成功后把正在购买商品Id属性充值为nil
    self.buyingProductId = nil;
    
    if (!self.isInAppVerify) { // 在自家服务器验证
        /*
         [self verifyPurchaseInServerWithTransaction:transaction result:^(BOOL isPassed, NSDictionary *resultDict, NSError *error) {
             // 服务器的验证结果
             if (isPassed) {
                 [self verifyPass:transaction];
             }
             else {
                 IAPLog(@"在server端验证失败：%@", error.localizedDescription);
             }
         }];
         */
        
        // 购买成功，验证放在，当外面收到购买成功的回调后再验证，不放在此类中验证了，太繁琐
        if (self.buyProductsCompleteBlock) self.buyProductsCompleteBlock(transaction);
    }
    else { // 在app内验证购买凭证
        __weak typeof(self) weakTarget = self;
        [self verifyPurchaseInAPPWithTransaction:transaction result:^(BOOL isPassed, NSDictionary *resultDict, NSError *error) {
            __strong typeof(weakTarget) self = weakTarget;
            // app跟苹果的验证结果
            if (isPassed) {
                [self verifyPass:transaction];
            }
            else {
                IAPLog(@"在iTunes端验证失败：%@", error.localizedDescription);
            }
        }];
    }
    
    // Remove the transaction from the payment queue.
    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
}

// 验证通过(此方法暂时用不到，校验是在外面处理的)
- (void)verifyPass:(SKPaymentTransaction *)transaction {
    if (transaction) {
        // 购买成功后添加到已购集合
        [self.purchasedProductSet addObject:transaction.payment.productIdentifier];
    }
    
    // block回调
    if (self.buyProductsCompleteBlock) self.buyProductsCompleteBlock(transaction);
    
    [[NSNotificationCenter defaultCenter] postNotificationName:PurchaseSuccessNotification object:nil userInfo:nil];
}

/// 交易失败
- (void)failedTransaction:(SKPaymentTransaction *)transaction {
    if(transaction.error.code == SKErrorPaymentCancelled) {
        IAPLog(@"用户取消交易");
    }
    else {
        IAPLog(@"购买失败：%@", transaction.error.localizedDescription);
    }
    
    NSString *errMsg = @"";
    switch (transaction.error.code) {
        case SKErrorPaymentCancelled:
            errMsg = @"交易取消";
            break;
        case SKErrorPaymentNotAllowed:
            errMsg = TEXT_APPLE_NOT_ALLOW;
            break;
        case SKErrorUnknown:
            errMsg = [transaction.error.localizedDescription containsString:@"iTunes Store"] ? transaction.error.localizedDescription : @"未知错误";
            break;
        case SKErrorPaymentInvalid:
            errMsg = @"购买凭证无效";
            break;
        case SKErrorClientInvalid:
            errMsg = @"购买请求无效";
            break;
        case SKErrorStoreProductNotAvailable:
            errMsg = @"该商品在当前店面不可用";
            break;
        default:
            errMsg = TEXT_APPLE_ERROR;
            break;
    }
    
    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
    
    // 回调
    if (self.buyProductsFailedBlock) self.buyProductsFailedBlock(transaction.error, errMsg);
}

/// 已经购买过该产品(在此处理恢复内购的逻辑)
- (void)restoreTransaction:(SKPaymentTransaction *)transaction {
    IAPLog(@"恢复内购时商品和交易的信息");
    IAPLog(@"transaction.transactionDate = %@", transaction.transactionDate);
    IAPLog(@"transaction.transactionIdentifier = %@", transaction.transactionIdentifier);
    IAPLog(@"transaction.originalTransaction.transactionIdentifier = %@", transaction.originalTransaction.transactionIdentifier);
    IAPLog(@"transaction.transactionState = %zd", transaction.transactionState);
    IAPLog(@"transaction.payment.productIdentifier = %@", transaction.payment.productIdentifier);
    
    [self completeTransaction:transaction isWillRestore:YES];
}

#pragma mark - 验证购买凭证
/*
/// 到服务器去验证购买凭证
- (void)verifyPurchaseInServerWithTransaction:(SKPaymentTransaction *)transaction
                                       result:(void (^)(BOOL isPassed, NSDictionary *resultDict, NSError *error))resultBlock {
// 充值凭证，也可以理解为🍎给的发票
    if (self.verifyDelegate && [self.verifyDelegate respondsToSelector:@selector(verifyReceiptInServer:onComplete:)]) {
        [self.verifyDelegate verifyReceiptInServer:transaction onComplete:^(BOOL verifyPass, NSDictionary *resultDict, NSError *error) {
            if (resultBlock) resultBlock(verifyPass, resultDict, error);
        }];
    }
// 不通过代理验证，直接在购买回调中验证
    else {
        if (self.buyProductsCompleteBlock) self.buyProductsCompleteBlock(transaction);
    }
}
 */

/// 在app中校验购买凭证
- (void)verifyPurchaseInAPPWithTransaction:(SKPaymentTransaction *)transaction
                                    result:(void(^)(BOOL isPassed, NSDictionary *resultDict, NSError *error))resultBlock {
    NSData *requestData = ({
        // 从沙盒中获取到购买凭据
        NSData *receiptData = [self receipData:transaction];
        
        NSString *encodeStr = [receiptData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];
        NSString *payload = [NSString stringWithFormat:@"{\"receipt-data\" : \"%@\"}", encodeStr];
        [payload dataUsingEncoding:NSUTF8StringEncoding];
    });
    
    // 发送网络POST请求，对购买凭据进行验证
    NSURL *url = [NSURL URLWithString:({
#if DEBUG
        self.isSandbox ? kSandboxVerify : kServerVerify;
#else
        kServerVerify;
#endif
    })];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10.0f];
    request.HTTPMethod = @"POST";
    request.HTTPBody = requestData;
    
    // 提交验证请求，并获得官方的验证JSON结果
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (data) {
            NSError *realizaError = nil;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&realizaError];
            if (error) IAPLog(@"验证结果解析失败：%@", error.localizedDescription);
            IAPLog(@"验证结果：%@", dict ?: @"失败");
            resultBlock(YES, dict, nil);
        }
        else {
            IAPLog(@"验证失败：%@", error.localizedDescription);
            resultBlock(NO, nil, error);
        }
    }] resume];
}

#pragma mark - 保存购买凭证

/// 记录购买凭证（数据库、钥匙串）
- (void)recordTransaction:(SKPaymentTransaction *)transaction product:(SKProduct *)product {
    NSCParameterAssert(transaction);
    if (!transaction) return;
    
    //[ZDStoreIAPReceipt storeTransaction:transaction product:product];
}

/*
/// 内购凭证存储路径
NSString *purchasedRecordFilePath() {
    NSString *documentDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documentDirectory stringByAppendingPathComponent:@"purchasedRecord.plist"];
}

- (void)restorePurchasedRecord {
    self.purchasedRecordDict = [[NSKeyedUnarchiver unarchiveObjectWithFile:purchasedRecordFilePath()] mutableCopy];
    if (!self.purchasedRecordDict) self.purchasedRecordDict = @{}.mutableCopy;
}

- (void)savePurchasedRecord {
    NSError *__autoreleasing *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.purchasedRecordDict];
    BOOL success = [data writeToFile:purchasedRecordFilePath() options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:error];
    if (!success) IAPLog(@"文件写入失败：%@", (*error).localizedDescription);
}
 */

#pragma mark - Getter

- (NSMutableSet *)purchasedProductSet {
    if (!_purchasedProductSet) {
        _purchasedProductSet = [[NSMutableSet alloc] init];
    }
    return _purchasedProductSet;
}

// 陌陌币、VIP、SVIP（(S)VIP目前都是自动续费的）
+ (NSSet *)allProductIdentifiers {
    NSSet *productIdentifiers = [NSSet setWithObjects:
                                 @"",
                                 nil];
    return productIdentifiers;
}

/// 陌陌币
+ (NSSet *)coinProductIdentifiers {
    NSSet *coinProductIds = [NSSet setWithObjects:
                                @"",
                                 nil];
    return coinProductIds;
}

/// (S)VIP
+ (NSSet *)vipProductIdentifiers {
    NSSet *vipProductIds = [NSSet setWithObjects:
                            @"",
                            nil];
    return vipProductIds;
}

/// 全部商品，包括自动续费的和非自动续费的
+ (NSSet *)backupAllProductIdentifiers __unavailable {
    NSSet *productIdentifiers = [NSSet setWithObjects:
                                 @"",
                                 nil];
    return productIdentifiers;
}

@end





