//
//  NSNotification+RNSwizzle.m
//  MethodSwizzle
//
//  Created by Rob Napier on 6/8/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "NSNotificationCenter+RNSwizzle.h"
#import "RNSwizzle.h"

@implementation NSNotificationCenter (RNSwizzle)

static IMP sOrigAddObserver = NULL;

static void MYAddObserver(id self, SEL _cmd, id observer, 
                          SEL selector,
                          NSString *name,
                          id sender) {
  NSLog(@"Adding observer: %@", observer);
  
  // Call the old implementation
  NSAssert(sOrigAddObserver,
           @"Original addObserver: method not found.");
  if (sOrigAddObserver) {
    sOrigAddObserver(self, _cmd, observer, selector, name, 
                     sender);
  }
}

+ (void)swizzleAddObserver {
  NSAssert(! sOrigAddObserver,
           @"Only call swizzleAddObserver once.");
  SEL sel = @selector(addObserver:selector:name:object:);
  sOrigAddObserver = (void *)[self swizzleSelector:sel
                              withIMP:(IMP)MYAddObserver];
}
@end
