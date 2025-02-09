/*
 
 CEKeyBindingManager.h
 
 CotEditor
 http://coteditor.com
 
 Created by nakamuxu on 2005-09-01.

 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2015 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

@import Cocoa;


// outlineView data key, column identifier
extern NSString *__nonnull const CEKeyBindingTitleKey;
extern NSString *__nonnull const CEKeyBindingChildrenKey;
extern NSString *__nonnull const CEKeyBindingKeySpecCharsKey;
extern NSString *__nonnull const CEKeyBindingSelectorStringKey;


@interface CEKeyBindingManager : NSObject

// singleton
+ (nonnull instancetype)sharedManager;


// Public methods
+ (nonnull NSString *)keySpecCharsFromKeyEquivalent:(nonnull NSString *)string modifierFrags:(NSEventModifierFlags)modifierFlags;
+ (nonnull NSString *)printableKeyStringFromKeySpecChars:(nonnull NSString *)string;

- (void)applyKeyBindingsToMainMenu;

- (nonnull NSString *)selectorStringWithKeyEquivalent:(nonnull NSString *)string modifierFrags:(NSEventModifierFlags)modifierFlags;

- (BOOL)usesDefaultMenuKeyBindings;
- (BOOL)usesDefaultTextKeyBindings;
- (nonnull NSMutableArray *)textKeySpecCharArrayForOutlineDataWithFactoryDefaults:(BOOL)usesFactoryDefaults;
- (nonnull NSMutableArray *)mainMenuArrayForOutlineData:(nonnull NSMenu *)menu;
- (nonnull NSString *)keySpecCharsInDefaultDictionaryFromSelectorString:(nonnull NSString *)selectorString;
- (BOOL)saveMenuKeyBindings:(nonnull NSArray *)outlineViewData;
- (BOOL)saveTextKeyBindings:(nonnull NSArray *)outlineViewData texts:(nullable NSArray *)texts;

@end



// Category for migration from CotEditor 1.x to 2.0. (2014-10)
// It can be removed when the most of users have been already migrated in the future.
@interface CEKeyBindingManager (Migration)

- (BOOL)resetMenuKeyBindings;

@end
