/*
 
 CESplitViewController.h
 
 CotEditor
 http://coteditor.com
 
 Created by nakamuxu on 2006-03-26.
 
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

@import AppKit;


@class CEEditorView;


@interface CESplitViewController : NSViewController <NSSplitViewDelegate>

- (nonnull NSSplitView *)splitView;

- (void)enumerateEditorViewsUsingBlock:(void (^ __nonnull)(CEEditorView * __nonnull editorView))block;

- (void)updateCloseSplitViewButton;

- (IBAction)toggleSplitOrientation:(nullable id)sender;
- (IBAction)focusNextSplitTextView:(nullable id)sender;
- (IBAction)focusPrevSplitTextView:(nullable id)sender;

@end
