/*
 
 CEThemeViewController.h
 
 CotEditor
 http://coteditor.com
 
 Created by 1024jp on 2014-09-12.

 ------------------------------------------------------------------------------
 
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


@protocol CEThemeViewControllerDelegate<NSObject>

@required
- (void)didUpdateTheme:(nonnull NSMutableDictionary *)theme;

@end



@interface CEThemeViewController : NSViewController

@property (nonatomic, nullable, weak) id<CEThemeViewControllerDelegate> delegate;
@property (nonatomic, getter=isBundled) BOOL bundled;

@end
