/*
 
 CEDocument.m
 
 CotEditor
 http://coteditor.com
 
 Created by nakamuxu on 2004-12-08.

 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2011,2014 usami-k
 © 2013-2015 1024jp
 
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

#import "CEDocument.h"
#import "CEDocumentController.h"
#import "CEPrintPanelAccessoryController.h"
#import "CEPrintView.h"
#import "CEODBEventSender.h"
#import "CESyntaxManager.h"
#import "CEUtils.h"
#import "NSURL+Xattr.h"
#import "NSData+MD5.h"
#import "Constants.h"


// constants
static char const UTF8_BOM[] = {0xef, 0xbb, 0xbf};

NSUInteger const CEUniqueFileIDLength = 8;
NSString *const CEWritablilityKey = @"writability";
NSString *const CEReadingEncodingKey = @"readingEncoding";
NSString *const CESyntaxStyleKey = @"syntaxStyle";
NSString *const CEAutosaveIdentierKey = @"autosaveIdentifier";

// incompatible chars dictionary keys
NSString *const CEIncompatibleLineNumberKey = @"lineNumber";
NSString *const CEIncompatibleRangeKey = @"incompatibleRange";
NSString *const CEIncompatibleCharKey = @"incompatibleChar";
NSString *const CEIncompatibleConvertedCharKey = @"convertedChar";


@interface CEDocument ()

@property (nonatomic) CEPrintPanelAccessoryController *printPanelAccessoryController;

@property (nonatomic) NSStringEncoding readingEncoding;  // encoding to read document file
@property (nonatomic) BOOL needsShowUpdateAlertWithBecomeKey;
@property (nonatomic, getter=isRevertingForExternalFileUpdate) BOOL revertingForExternalFileUpdate;
@property (nonatomic) BOOL didAlertNotWritable;  // 文書が読み込み専用のときにその警告を表示したかどうか
@property (nonatomic, copy) NSString *fileMD5;
@property (nonatomic, copy) NSString *fileContentString;  // string that is read from the document file
@property (nonatomic, getter=isVerticalText) BOOL verticalText;
@property (nonatomic) CEODBEventSender *ODBEventSender;
@property (nonatomic) BOOL shouldSaveXattr;
@property (nonatomic, copy) NSString *autosaveIdentifier;
@property (nonatomic) BOOL suppressesIANACharsetConflictAlert;

// readonly
@property (readwrite, nonatomic) CEWindowController *windowController;
@property (readwrite, nonatomic) CETextSelection *selection;
@property (readwrite, nonatomic) NSStringEncoding encoding;
@property (readwrite, nonatomic) CENewLineType lineEnding;
@property (readwrite, nonatomic, copy) NSDictionary *fileAttributes;
@property (readwrite, nonatomic, getter=isWritable) BOOL writable;

@end




#pragma mark -

@implementation CEDocument

#pragma mark Superclass Methods

// ------------------------------------------------------
/// enable Autosave in Place
+ (BOOL)autosavesInPlace
// ------------------------------------------------------
{
    static dispatch_once_t onceToken;
    static BOOL autosavesInPlace;
    
    // avoid changing the value while the application is running
    dispatch_once(&onceToken, ^{
        autosavesInPlace = [[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultEnablesAutosaveInPlaceKey];
    });
    
    return autosavesInPlace;
}


// ------------------------------------------------------
/// initialize instance
- (nonnull instancetype)init
// ------------------------------------------------------
{
    self = [super init];
    if (self) {
        [self setHasUndoManager:YES];
        
        _encoding = [[NSUserDefaults standardUserDefaults] integerForKey:CEDefaultEncodingInNewKey];
        _lineEnding = [[NSUserDefaults standardUserDefaults] integerForKey:CEDefaultLineEndCharCodeKey];
        _selection = [[CETextSelection alloc] initWithDocument:self];
        _writable = YES;
        _shouldSaveXattr = YES;
        _autosaveIdentifier = [[[NSUUID UUID] UUIDString] substringToIndex:CEUniqueFileIDLength];
        
        // set encoding to read file
        // -> The value is either user setting or selection of open panel.
        // -> This must be set before `readFromData:ofType:error:` is called.
        _readingEncoding = [[CEDocumentController sharedDocumentController] accessorySelectedEncoding];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(documentDidFinishOpen:)
                                                     name:CEDocumentDidFinishOpenNotification object:nil];
        
        // alert about file modification by an external process when application becomes active
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(showUpdatedByExternalProcessAlert)
                                                     name:NSApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}


// ------------------------------------------------------
/// initialize instance with existing file
- (nullable instancetype)initWithContentsOfURL:(nonnull NSURL *)url ofType:(nonnull NSString *)typeName error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    // This method won't be invoked on Resume. (2015-01-26)
    
    self = [super initWithContentsOfURL:url ofType:typeName error:outError];
    if (self) {
        // set sender of external editor protocol (ODB Editor Suite)
        _ODBEventSender = [[CEODBEventSender alloc] init];
        
        // check writability
        NSNumber *isWritable = nil;
        [url getResourceValue:&isWritable forKey:NSURLIsWritableKey error:nil];
        _writable = [isWritable boolValue];
        
        // check file meta data for text orientation
        if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultSavesTextOrientationKey]) {
            _verticalText = [url getXattrBoolForName:XATTR_VERTICAL_TEXT_NAME];
        }
    }
    return self;
}


// ------------------------------------------------------
/// clean up
- (void)dealloc
// ------------------------------------------------------
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


// ------------------------------------------------------
/// make custom windowControllers
- (void)makeWindowControllers
// ------------------------------------------------------
{
    [self setWindowController:[[CEWindowController alloc] initWithWindowNibName:@"DocumentWindow"]];
    [self addWindowController:[self windowController]];
}


// ------------------------------------------------------
/// load document from file and return whether it succeeded
- (BOOL)readFromData:(nonnull NSData *)data ofType:(nonnull NSString *)typeName error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    // store file hash (MD5) in order to check the file content identity in `presentedItemDidChange`
    [self setFileMD5:[data MD5]];
    
    // read file attributes
    if ([self fileURL]) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[[self fileURL] path] error:outError];
        [self setFileAttributes:attributes];
    }
    
    // try reading the `com.apple.TextEncoding` extended attribute
    NSStringEncoding xattrEncoding = [self fileURL] ? [[self fileURL] getXattrEncoding] : NSNotFound;
    
    // don't save xattr if file doesn't have it in order to avoid saving wrong encoding (2015-01 by 1024jp).
    [self setShouldSaveXattr:(xattrEncoding != NSNotFound) || ([data length] == 0)];
    
    NSStringEncoding usedEncoding;
    NSString *string = [self stringFromData:data encoding:[self readingEncoding] xattrEncoding:xattrEncoding usedEncoding:&usedEncoding error:outError];
    
    if (!string) { return NO; }
    
    // set read values
    [self setFileContentString:string];  // _fileContentString will be released in `setStringToEditor`
    [self setEncoding:usedEncoding];
    
    CENewLineType lineEnding = [string detectNewLineType];
    if (lineEnding != CENewLineNone) {  // keep default if no line endings are found
        [self setLineEnding:lineEnding];
    }
    
    return YES;
}


// ------------------------------------------------------
/// revert to saved file contents
- (BOOL)revertToContentsOfURL:(nonnull NSURL *)url ofType:(nonnull NSString *)typeName error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    BOOL success = [super revertToContentsOfURL:url ofType:typeName error:outError];
    
    // apply to UI
    if (success) {
        [self applyContentToEditor];
        [[self windowController] updateFileInfo];
    }
    
    return success;
}


// ------------------------------------------------------
/// create NSData object to save
- (nullable NSData *)dataOfType:(nonnull NSString *)typeName error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    NSStringEncoding encoding = [self encoding];
    
    // convert Yen sign in consideration of the current encoding
    NSString *string = [self convertCharacterString:[self stringForSave] encoding:encoding];
    
    // unblock the user interface, since fetching current document satte has been done here
    [self unblockUserInteraction];
    
    // get data from string to save
    NSData *data = [string dataUsingEncoding:encoding allowLossyConversion:YES];
    
    // add UTF-8 BOM if needed
    if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultSaveUTF8BOMKey] &&
        (encoding == NSUTF8StringEncoding))
    {
        NSMutableData *mutableData = [NSMutableData dataWithBytes:UTF8_BOM length:3];
        [mutableData appendData:data];
        data = [NSData dataWithData:mutableData];
    }
    
    return data;
}


// ------------------------------------------------------
/// enable asynchronous saving
- (BOOL)canAsynchronouslyWriteToURL:(nonnull NSURL *)url ofType:(nonnull NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation
// ------------------------------------------------------
{
    return (saveOperation == NSAutosaveElsewhereOperation ||
            saveOperation == NSAutosaveInPlaceOperation);
}


// ------------------------------------------------------
/// save or autosave the document contents to a file
- (void)saveToURL:(nonnull NSURL *)url ofType:(nonnull NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation completionHandler:(nonnull void (^)(NSError * __nullable))completionHandler
// ------------------------------------------------------
{
    // break undo grouping
    [[[self editor] focusedTextView] breakUndoCoalescing];
    
    // modify place to create backup file
    //   -> save backup file always in `~/Library/Autosaved Information/` direcotory
    //      (The default backup URL is the same directory as the fileURL.)
    if (saveOperation == NSAutosaveElsewhereOperation && [self fileURL]) {
        NSURL *autosaveDirectoryURL =  [[CEDocumentController sharedDocumentController] autosaveDirectoryURL];
        NSString *baseFileName = [[self fileURL] lastPathComponent];
        if ([baseFileName hasPrefix:@"."]) {  // avoid file to be hidden
            baseFileName = [baseFileName substringFromIndex:1];
        }
        NSString *fileName = [NSString stringWithFormat:@"%@ (%@)",
                              [baseFileName stringByDeletingPathExtension],
                              [self autosaveIdentifier]];  // append a unique string to avoid overwriting another backup file with the same file name.
        
        url = [[autosaveDirectoryURL URLByAppendingPathComponent:fileName] URLByAppendingPathExtension:[baseFileName pathExtension]];
    }
    
    // store current state here, since the main thread will already be unblocked after `dataOfType:error:`
    NSStringEncoding encoding = [self encoding];
    BOOL isVerticalText = [[self editor] isVerticalLayoutOrientation];
    
    __weak typeof(self) weakSelf = self;
    [super saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError *error)
     {
         // [note] This completionHandler block will always be invoked on the main thread.
         
         typeof(self) self = weakSelf;  // strong self
         
         if (!error) {
             // write encoding to the external file attributes (com.apple.TextEncoding)
             if ([self shouldSaveXattr]) {
                 [url setXattrEncoding:encoding];
             }
             // save text orientation state
             if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultSavesTextOrientationKey]) {
                 [url setXattrBool:isVerticalText forName:XATTR_VERTICAL_TEXT_NAME];
             }
             
             // apply syntax style that is inferred from the file name
             if (saveOperation == NSSaveAsOperation) {
                 NSString *styleName = [[CESyntaxManager sharedManager] styleNameFromFileName:[url lastPathComponent]];
                 if (styleName) {
                     [self setSyntaxStyleWithName:styleName coloring:YES];
                 }
             }
             
             if (saveOperation != NSAutosaveElsewhereOperation) {
                 // update file information
                 [[self windowController] updateFileInfo];
                 
                 // send file update notification for the external editor protocol (ODB Editor Suite)
                 [[self ODBEventSender] sendModifiedEventWithURL:url operation:saveOperation];
             }
         }
         
         completionHandler(error);
     }];
}


// ------------------------------------------------------
/// ファイルの保存(保存処理で包括的に呼ばれる)
- (BOOL)writeToURL:(nonnull NSURL *)url ofType:(nonnull NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation originalContentsURL:(nullable NSURL *)absoluteOriginalContentsURL error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    // [caution] This method may be called from a background thread due to async-saving.
    
    // store current state here, since the main thread will already be unblocked after `dataOfType:error:`
    NSStringEncoding encoding = [self encoding];
    
    BOOL success = [super writeToURL:url ofType:typeName forSaveOperation:saveOperation originalContentsURL:absoluteOriginalContentsURL error:outError];

    if (success) {
        if (saveOperation != NSAutosaveElsewhereOperation) {
            // store file hash (MD5) in order to check the file content identity in `presentedItemDidChange`
            NSData *data = [NSData dataWithContentsOfURL:url];
            [self setFileMD5:[data MD5]];
            
            // store file encoding for revert
            [self setReadingEncoding:encoding];
            
            // store file attributes
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:nil];
            [self setFileAttributes:attributes];
        }
    }

    return success;
}


// ------------------------------------------------------
/// セーブパネルへ標準のアクセサリビュー(ポップアップメニューでの書類の切り替え)を追加しない
- (BOOL)shouldRunSavePanelWithAccessoryView
// ------------------------------------------------------
{
    return NO;
}


// ------------------------------------------------------
/// セーブパネルを準備
- (BOOL)prepareSavePanel:(nonnull NSSavePanel *)savePanel
// ------------------------------------------------------
{
    // reset file types, otherwise:
    //   - alert dialog will be displayed if user inputs another extension.
    //   - cannot save without extension.
    [savePanel setAllowedFileTypes:nil];
    
    // disable hide extension checkbox
    [savePanel setExtensionHidden:NO];
    [savePanel setCanSelectHiddenExtension:NO];
    
    // append file extension as a part of the file name, if it is the first save.
    if (![self fileURL]) {
        NSString *extension = [self preferredExtension];
        if (extension) {
            [savePanel setNameFieldStringValue:[[savePanel nameFieldStringValue] stringByAppendingPathExtension:extension]];
        }
    }
    
    return [super prepareSavePanel:savePanel];
}


// ------------------------------------------------------
/// ドキュメントが閉じられる前に保存のためのダイアログの表示などを行う
- (void)canCloseDocumentWithDelegate:(nonnull id)delegate shouldCloseSelector:(nullable SEL)shouldCloseSelector contextInfo:(nullable void *)contextInfo
// ------------------------------------------------------
{
    // Disable save dialog if content is empty and not saved
    if (![self fileURL] && [[[self editor] string] length] == 0) {
        [self updateChangeCount:NSChangeCleared];
    }
    
    [super canCloseDocumentWithDelegate:delegate shouldCloseSelector:shouldCloseSelector contextInfo:contextInfo];
}


// ------------------------------------------------------
/// ドキュメントを閉じる
- (void)close
// ------------------------------------------------------
{
    // send file close notification for the external editor protocol (ODB Editor Suite)
    if ([self fileURL]) {
        [[self ODBEventSender] sendCloseEventWithURL:[self fileURL]];
    }
    
    [super close];
}


// ------------------------------------------------------
/// プリントパネルを含むプリント用設定を生成して返す
- (nullable NSPrintOperation *)printOperationWithSettings:(nonnull NSDictionary *)printSettings error:(NSError * __nullable __autoreleasing * __nullable)outError
// ------------------------------------------------------
{
    if (![self printPanelAccessoryController]) {
        [self setPrintPanelAccessoryController:[[CEPrintPanelAccessoryController alloc] init]];
    }
    CEPrintPanelAccessoryController *accessoryController = [self printPanelAccessoryController];
    
    // create printView
    CEPrintView *printView = [[CEPrintView alloc] init];
    [printView setString:[[self editor] string]];
    [printView setLayoutOrientation:[[[self editor] focusedTextView] layoutOrientation]];
    [printView setTheme:[[self editor] theme]];
    [printView setDocumentName:[self displayName]];
    [printView setFilePath:[[self fileURL] path]];
    [printView setSyntaxName:[[self editor] syntaxStyleName]];
    [printView setDocumentShowsInvisibles:[[self editor] showsInvisibles]];
    [printView setDocumentShowsLineNum:[[self editor] showsLineNum]];
    [printView setLineSpacing:[[[self editor] focusedTextView] lineSpacing]];
    
    // set font for printing
    NSFont *font;
    if ([[NSUserDefaults standardUserDefaults] integerForKey:CEDefaultSetPrintFontKey] == 1) { // == プリンタ専用フォントで印字
        font = [NSFont fontWithName:[[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultPrintFontNameKey]
                               size:(CGFloat)[[NSUserDefaults standardUserDefaults] doubleForKey:CEDefaultPrintFontSizeKey]];
    } else {
        font = [[self editor] font];
    }
    [printView setFont:font];
    
    // setup PrintInfo
    NSPrintInfo *printInfo = [self printInfo];
    [printInfo setHorizontalPagination:NSFitPagination];
    [printInfo setHorizontallyCentered:NO];
    [printInfo setVerticallyCentered:NO];
    [printInfo setLeftMargin:kHorizontalPrintMargin];
    [printInfo setRightMargin:kHorizontalPrintMargin];
    [printInfo setTopMargin:kVerticalPrintMargin];
    [printInfo setBottomMargin:kVerticalPrintMargin];
    [printInfo dictionary][NSPrintHeaderAndFooter] = @YES;
    
    // create print operation
    NSPrintOperation *printOperation = [NSPrintOperation printOperationWithView:printView printInfo:printInfo];
    [printOperation setJobTitle:[self displayName]];
    [printOperation setShowsProgressPanel:YES];
    [[printOperation printPanel] addAccessoryController:accessoryController];
    [[printOperation printPanel] setOptions:NSPrintPanelShowsCopies | NSPrintPanelShowsPageRange | NSPrintPanelShowsPaperSize | NSPrintPanelShowsOrientation | NSPrintPanelShowsScaling | NSPrintPanelShowsPreview];
    
    return printOperation;
}


// ------------------------------------------------------
/// store internal document state
- (void)encodeRestorableStateWithCoder:(nonnull NSCoder *)coder
// ------------------------------------------------------
{
    [coder encodeBool:[self isWritable] forKey:CEWritablilityKey];
    [coder encodeInteger:[self encoding] forKey:CEReadingEncodingKey];
    [coder encodeObject:[self autosaveIdentifier] forKey:CEAutosaveIdentierKey];
    [coder encodeObject:[[self editor] syntaxStyleName] forKey:CESyntaxStyleKey];
    
    [super encodeRestorableStateWithCoder:coder];
}


// ------------------------------------------------------
/// resume UI state
- (void)restoreStateWithCoder:(nonnull NSCoder *)coder
// ------------------------------------------------------
{
    [super restoreStateWithCoder:coder];
    
    if ([coder containsValueForKey:CEWritablilityKey]) {
        [self setWritable:[coder decodeBoolForKey:CEWritablilityKey]];
    }
    if ([coder containsValueForKey:CEReadingEncodingKey]) {
        [self setReadingEncoding:[coder decodeIntegerForKey:CEReadingEncodingKey]];
    }
    if ([coder containsValueForKey:CEAutosaveIdentierKey]) {
        [self setAutosaveIdentifier:[coder decodeObjectForKey:CEAutosaveIdentierKey]];
    }
    
    // restore last syntax style
    if ([coder containsValueForKey:CESyntaxStyleKey]) {
        NSString *syntaxStyle = [coder decodeObjectForKey:CESyntaxStyleKey];
        if (![syntaxStyle isEqualToString:[[self editor] syntaxStyleName]]) {  // avoid highlighting twice
            [[self editor] setSyntaxStyleWithName:syntaxStyle coloring:YES];
            [[[self windowController] toolbarController] setSelectedSyntaxWithName:syntaxStyle];
        }
    }
    
    // not need to show unwritable alert on resume
    [self setDidAlertNotWritable:YES];
}



#pragma mark Protocol

//=======================================================
// NSMenuValidation Protocol
//=======================================================

// ------------------------------------------------------
/// メニュー項目の有効・無効を制御
- (BOOL)validateMenuItem:(nonnull NSMenuItem *)menuItem
// ------------------------------------------------------
{
    NSInteger state = NSOffState;
    NSString *name;
    
    if ([menuItem action] == @selector(saveDocument:)) {
        // 書き込み不可の時は、アラートが表示され「OK」されるまで保存メニューを無効化する
        return ([self isWritable] || [self didAlertNotWritable]);
    } else if ([menuItem action] == @selector(changeEncoding:)) {
        state = ([menuItem tag] == [self encoding]) ? NSOnState : NSOffState;
    } else if (([menuItem action] == @selector(changeLineEndingToLF:)) ||
               ([menuItem action] == @selector(changeLineEndingToCR:)) ||
               ([menuItem action] == @selector(changeLineEndingToCRLF:)) ||
               ([menuItem action] == @selector(changeLineEnding:)))
    {
        state = ([menuItem tag] == [self lineEnding]) ? NSOnState : NSOffState;
    } else if ([menuItem action] == @selector(changeTheme:)) {
        name = [[[self editor] theme] name];
        if (name && [[menuItem title] isEqualToString:name]) {
            state = NSOnState;
        }
    } else if ([menuItem action] == @selector(changeSyntaxStyle:)) {
        name = [[self editor] syntaxStyleName];
        if (name && [[menuItem title] isEqualToString:name]) {
            state = NSOnState;
        }
    } else if ([menuItem action] == @selector(recolorAll:)) {
        name = [[self editor] syntaxStyleName];
        if (name && [name isEqualToString:NSLocalizedString(@"None", @"")]) {
            return NO;
        }
    }
    [menuItem setState:state];
    
    return [super validateMenuItem:menuItem];
}


//=======================================================
// NSToolbarItemValidation Protocol
//=======================================================

// ------------------------------------------------------
/// ツールバー項目の有効・無効を制御
- (BOOL)validateToolbarItem:(nonnull NSToolbarItem *)theItem
// ------------------------------------------------------
{
    if ([theItem action] == @selector(recolorAll:)) {
        NSString *name = [[self editor] syntaxStyleName];
        if ([name isEqualToString:NSLocalizedString(@"None", @"")]) {
            return NO;
        }
    }
    
    return YES;
}


//=======================================================
// NSFilePresenter Protocol
//=======================================================

// ------------------------------------------------------
/// file location has changed
- (void)presentedItemDidMoveToURL:(nonnull NSURL *)newURL
// ------------------------------------------------------
{
    [super presentedItemDidMoveToURL:newURL];
    
    CEWindowController *windowController = [self windowController];
    dispatch_async(dispatch_get_main_queue(), ^{
        [windowController updateFileInfo];
    });
}


// ------------------------------------------------------
/// file has been modified by an external process
- (void)presentedItemDidChange
// ------------------------------------------------------
{
    // [caution] This method can be called from any thread.
    
    CEDocumentConflictOption option = [[NSUserDefaults standardUserDefaults] integerForKey:CEDefaultDocumentConflictOptionKey];
    
    // do nothing
    if (option == CEDocumentConflictIgnore) { return; }
    
    // don't check twice if document is already marked as modified
    if ([self needsShowUpdateAlertWithBecomeKey]) { return; }
    
    // ignore if file's modificationDate is the same as document's modificationDate
    __block NSDate *fileModificationDate;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:self];
    [coordinator coordinateReadingItemAtURL:[self fileURL] options:NSFileCoordinatorReadingWithoutChanges
                                      error:nil byAccessor:^(NSURL *newURL)
     {
         NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[newURL path] error:nil];
         fileModificationDate = [fileAttrs fileModificationDate];
     }];
    if ([fileModificationDate isEqualTo:[self fileModificationDate]]) { return; }
    
    // ignore if file's MD5 hash is the same as the stored MD5 and deal as if it was not modified
    __block NSString *MD5;
    [coordinator coordinateReadingItemAtURL:[self fileURL] options:NSFileCoordinatorReadingWithoutChanges
                                      error:nil byAccessor:^(NSURL *newURL)
     {
         MD5 = [[NSData dataWithContentsOfURL:newURL] MD5];
     }];
    if ([MD5 isEqualToString:[self fileMD5]]) {
        // update the document's fileModificationDate for a workaround (2014-03 by 1024jp)
        // If not, an alert shows up when user saves the file.
        if ([fileModificationDate compare:[self fileModificationDate]] == NSOrderedDescending) {
            [self setFileModificationDate:fileModificationDate];
        }
        
        return;
    }
    
    // notify about external file update
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;  // strong self
        if (!self) { return; }
        
        if (option == CEDocumentConflictRevert) {
            // revert
            [self revertToContentsOfURL:[self fileURL] ofType:[self fileType] error:nil];
            
        } else {
            // notify and show dialog later
            [self notifyExternalFileUpdate];
        }
    });
}



#pragma mark Public Methods

// ------------------------------------------------------
/// 改行コードを指定のものに置換したメイン textView の文字列を返す
- (NSString *)stringForSave
// ------------------------------------------------------
{
    return [[[self editor] string] stringByReplacingNewLineCharacersWith:[self lineEnding]];
}


// ------------------------------------------------------
/// transfer file content string to editor
- (void)applyContentToEditor
// ------------------------------------------------------
{
    NSString *styleName = [[CESyntaxManager sharedManager] styleNameFromFileName:[[self fileURL] lastPathComponent]];
    if (!styleName && [self fileContentString]) {
        NSString *interpreter = [self scanLanguageFromShebangInString:[self fileContentString]];
        styleName = [[CESyntaxManager sharedManager] styleNameFromInterpreter:interpreter];
    }
    styleName = styleName ? : [[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultSyntaxStyleKey];
    [self setSyntaxStyleWithName:styleName coloring:NO];
    
    // standardize line endings to LF (File Open)
    // (Line endings replacemement by other text modifications are processed in the following methods.)
    //
    // # Methods Standardizing Line Endings on Text Editing
    //   - File Open:
    //       - CEDocument > setStringToEditor
    //   - Key Typing, Script, Paste, Drop:
    //       - CEEditorView > textView:shouldChangeTextInRange:replacementString:
    //   - Replace on Find Panel:
    //       - (OgreKit) OgreTextViewPlainAdapter > replaceCharactersInRange:withOGString:
    
    if ([self fileContentString]) {
        NSString *string = [[self fileContentString] stringByReplacingNewLineCharacersWith:CENewLineLF];
        
        [[self editor] setString:string];  // In this `setString:`, caret will be moved to the beginning.
        [self setFileContentString:nil];  // release
        
    } else {
        [[self editor] setString:@""];
    }
    
    // update syntax highlights and outline menu
    [[self editor] invalidateSyntaxColoring];
    [[self editor] invalidateOutlineMenu];
    
    // update line endings menu selection in toolbar
    [self applyLineEndingToView];
    
    // apply text orientation
    [[self editor] setVerticalLayoutOrientation:[self isVerticalText]];
    
    // update encoding menu selection in toolbar, status bar and document inspector
    [self updateEncodingInToolbarAndInfo];
    
    // show incompatible chars if needed
    [[self windowController] updateIncompatibleCharsIfNeeded];
}


// ------------------------------------------------------
/// 設定されたエンコーディングの IANA Charset 名を返す
- (NSString *)currentIANACharSetName
// ------------------------------------------------------
{
    CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding([self encoding]);
    
    if (cfEncoding == kCFStringEncodingInvalidId) { return nil; }
    
    return (NSString *)CFStringConvertEncodingToIANACharSetName(cfEncoding);
}


// ------------------------------------------------------
/// 指定されたエンコードにコンバートできない文字列をリストアップし配列を返す
- (NSArray *)findCharsIncompatibleWithEncoding:(NSStringEncoding)encoding
// ------------------------------------------------------
{
    NSMutableArray *incompatibleChars = [NSMutableArray array];
    NSString *currentString = [self stringForSave];
    NSUInteger currentLength = [currentString length];
    NSData *data = [currentString dataUsingEncoding:encoding allowLossyConversion:YES];
    NSString *convertedString = [[NSString alloc] initWithData:data encoding:encoding];
    
    if (!convertedString || ([convertedString length] != currentLength)) { // 正しいリストが取得できない時
        return nil;
    }
    
    // 削除／変換される文字をリストアップ
    BOOL isInvalidYenEncoding = [CEUtils isInvalidYenEncoding:encoding];
    
    for (NSUInteger i = 0; i < currentLength; i++) {
        unichar currentUnichar = [currentString characterAtIndex:i];
        unichar convertedUnichar = [convertedString characterAtIndex:i];
        
        if (currentUnichar == convertedUnichar) { continue; }
        
        if (isInvalidYenEncoding && currentUnichar == kYenMark) {
            convertedUnichar = '\\';
        }
        
        NSString *currentChar = [NSString stringWithCharacters:&currentUnichar length:1];
        NSString *convertedChar = [NSString stringWithCharacters:&convertedUnichar length:1];
        
        NSUInteger lineNumber = 1;
        for (NSUInteger index = 0, lines = 0; index < currentLength; lines++) {
            if (index <= i) {
                lineNumber = lines + 1;
            } else {
                break;
            }
            index = NSMaxRange([currentString lineRangeForRange:NSMakeRange(index, 0)]);
        }
        
        [incompatibleChars addObject:@{CEIncompatibleLineNumberKey: @(lineNumber),
                                       CEIncompatibleRangeKey: [NSValue valueWithRange:NSMakeRange(i, 1)],
                                       CEIncompatibleCharKey: currentChar,
                                       CEIncompatibleConvertedCharKey: convertedChar}];
    }
    
    return [incompatibleChars copy];
}


// ------------------------------------------------------
/// 指定されたエンコーディングでファイルを再解釈する
- (BOOL)reinterpretWithEncoding:(NSStringEncoding)encoding error:(NSError *__autoreleasing __nullable *)outError
// ------------------------------------------------------
{
    BOOL success = NO;
    
    if (encoding == NSNotFound || ![self fileURL]) {
        if (outError) {
            // TODO: add userInfo (The outError under this condition will actually not be used, but better not to pass an empty errer pointer.)
            *outError = [NSError errorWithDomain:CEErrorDomain code:CEReinterpretationFailedError userInfo:nil];
        }
        return NO;
    }
    
    // do nothing if given encoding is the same as current one
    if (encoding == [self encoding]) { return YES; }
    
    // reinterpret
    [self setReadingEncoding:encoding];
    success = [self revertToContentsOfURL:[self fileURL] ofType:[self fileType] error:nil];
    
    // set outError
    if (!success && outError) {
        NSString *encodingName = [NSString localizedNameOfStringEncoding:encoding];
        NSDictionary *userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Can not reinterpret", nil),
                                   NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"The file “%@” could not be reinterpreted using the new encoding “%@”.", nil), [[self fileURL] path], encodingName],
                                   NSStringEncodingErrorKey: @(encoding),
                                   NSURLErrorKey: [self fileURL],
                                   };
        *outError = [NSError errorWithDomain:CEErrorDomain code:CEReinterpretationFailedError userInfo:userInfo];
    }
    
    return success;
}


// ------------------------------------------------------
/// 新規エンコーディングをセット
- (BOOL)doSetEncoding:(NSStringEncoding)encoding updateDocument:(BOOL)updateDocument askLossy:(BOOL)askLossy lossy:(BOOL)lossy asActionName:(NSString *)actionName
// ------------------------------------------------------
{
    if (encoding == [self encoding]) {
        return YES;
    }
    
    BOOL shouldShowList = NO;
    
    if (updateDocument) {
        NSString *curString = [self stringForSave];
        BOOL allowsLossy = NO;

        if (askLossy) {
            if (![curString canBeConvertedToEncoding:encoding]) {
                NSString *encodingNameStr = [NSString localizedNameOfStringEncoding:encoding];
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"The characters would have to be changed or deleted in saving as “%@”.", nil), encodingNameStr]];
                [alert setInformativeText:NSLocalizedString(@"Do you want to change encoding and show incompatible characters?", nil)];
                [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
                [alert addButtonWithTitle:NSLocalizedString(@"Change Encoding", nil)];

                NSInteger returnCode = [alert runModal];
                if (returnCode == NSAlertFirstButtonReturn) { // == Cancel
                    return NO;
                }
                shouldShowList = YES;
                allowsLossy = YES;
            }
        } else {
            allowsLossy = lossy;
        }
        
        // register undo
        NSUndoManager *undoManager = [self undoManager];
        [[undoManager prepareWithInvocationTarget:self] redoSetEncoding:encoding updateDocument:updateDocument
                                                               askLossy:NO lossy:allowsLossy
                                                           asActionName:actionName];  // redo in undo
        if (shouldShowList) {
            [[undoManager prepareWithInvocationTarget:[self windowController]] showIncompatibleCharList];
        }
        [[undoManager prepareWithInvocationTarget:self] updateEncodingInToolbarAndInfo];
        [[undoManager prepareWithInvocationTarget:self] setEncoding:[self encoding]];  // エンコード値設定
        if (actionName) {
            [undoManager setActionName:actionName];
        }
    }
    
    [self setEncoding:encoding];
    [self updateEncodingInToolbarAndInfo];  // ツールバーのエンコーディングメニュー、ステータスバー、インスペクタを更新
    
    if (shouldShowList) {
        [[self windowController] showIncompatibleCharList];
    } else {
        [[self windowController] updateIncompatibleCharsIfNeeded];
    }
    
    return YES;
}


// ------------------------------------------------------
/// 改行コードを変更する
- (void)doSetLineEnding:(CENewLineType)lineEnding
// ------------------------------------------------------
{
    if (lineEnding == [self lineEnding]) { return; }
    
    CENewLineType currentLineEnding = [self lineEnding];

    // register undo
    NSUndoManager *undoManager = [self undoManager];
    [[undoManager prepareWithInvocationTarget:self] redoSetLineEnding:lineEnding];  // redo in undo
    [[undoManager prepareWithInvocationTarget:self] applyLineEndingToView];
    [[undoManager prepareWithInvocationTarget:self] setLineEnding:currentLineEnding];
    [undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Line Endings to “%@”", nil),
                                [NSString newLineNameWithType:lineEnding]]];

    [self setLineEnding:lineEnding];
    [self applyLineEndingToView];
}


// ------------------------------------------------------
/// 新しいシンタックスカラーリングスタイルを適用
- (void)doSetSyntaxStyle:(NSString *)name
// ------------------------------------------------------
{
    if ([name length] == 0) { return; }
    
    [[self editor] setSyntaxStyleWithName:name coloring:YES];
    [[[self windowController] toolbarController] setSelectedSyntaxWithName:name];
}



#pragma mark Notifications

//=======================================================
// Notification  <- CEWindowController
//=======================================================

// ------------------------------------------------------
/// 書類オープン処理が完了した
- (void)documentDidFinishOpen:(nonnull NSNotification *)notification
// ------------------------------------------------------
{
    if ([notification object] == [self windowController] && ![self isInViewingMode]) {
        // 書き込み禁止アラートを表示
        [self showNotWritableAlert];
    }
}



#pragma mark Action Messages

// ------------------------------------------------------
/// 保存
- (IBAction)saveDocument:(nullable id)sender
// ------------------------------------------------------
{
    if (![self acceptsSaveDocumentWithIANACharSetName]) { return; }
    if (![self acceptsSaveDocumentToConvertEncoding]) { return; }
    
    [super saveDocument:sender];
}


// ------------------------------------------------------
/// 別名で保存
- (IBAction)saveDocumentAs:(nullable id)sender
// ------------------------------------------------------
{
    if (![self acceptsSaveDocumentWithIANACharSetName]) { return; }
    if (![self acceptsSaveDocumentToConvertEncoding]) { return; }
    
    [super saveDocumentAs:sender];
}


// ------------------------------------------------------
/// ドキュメントに新しい改行コードをセットする
- (IBAction)changeLineEndingToLF:(nullable id)sender
// ------------------------------------------------------
{
    [self doSetLineEnding:CENewLineLF];
}


// ------------------------------------------------------
/// ドキュメントに新しい改行コードをセットする
- (IBAction)changeLineEndingToCR:(nullable id)sender
// ------------------------------------------------------
{
    [self doSetLineEnding:CENewLineCR];
}


// ------------------------------------------------------
/// ドキュメントに新しい改行コードをセットする
- (IBAction)changeLineEndingToCRLF:(nullable id)sender
// ------------------------------------------------------
{
    [self doSetLineEnding:CENewLineCRLF];
}


// ------------------------------------------------------
/// ドキュメントに新しい改行コードをセットする
- (IBAction)changeLineEnding:(nullable id)sender
// ------------------------------------------------------
{
    [self doSetLineEnding:[sender tag]];
}


// ------------------------------------------------------
/// ドキュメントに新しいエンコーディングをセットする
- (IBAction)changeEncoding:(nullable id)sender
// ------------------------------------------------------
{
    NSStringEncoding encoding = [sender tag];

    if ((encoding < 1) || (encoding == [self encoding])) { return; }
    
    NSInteger result;
    NSString *encodingName = [sender title];

    // 文字列がないまたは未保存の時は直ちに変換プロセスへ
    if (([[[self editor] string] length] < 1) || (![self fileURL])) {
        result = NSAlertFirstButtonReturn;
        
    } else {
        // 変換するか再解釈するかの選択ダイアログを表示
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"File encoding", nil)];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Do you want to convert or reinterpret it using “%@”?", nil), encodingName]];
        [alert addButtonWithTitle:NSLocalizedString(@"Convert", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Reinterpret", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

        result = [alert runModal];
    }
    
    if (result == NSAlertFirstButtonReturn) {  // = Convert 変換
        NSString *actionName = [NSString stringWithFormat:NSLocalizedString(@"Encoding to “%@”", nil),
                                [NSString localizedNameOfStringEncoding:encoding]];

        [self doSetEncoding:encoding updateDocument:YES askLossy:YES lossy:NO asActionName:actionName];

    } else if (result == NSAlertSecondButtonReturn) {  // = Reinterpret 再解釈
        if (![self fileURL]) { return; } // まだファイル保存されていない時（ファイルがない時）は、戻る
        if ([self isDocumentEdited]) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"The file “%@” has unsaved changes.", nil), [[self fileURL] path]]];
             [alert setInformativeText:NSLocalizedString(@"Do you want to discard the changes and reset the file encoding?", nil)];
             [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
             [alert addButtonWithTitle:NSLocalizedString(@"Discard Changes", nil)];

            NSInteger secondResult = [alert runModal];
            if (secondResult != NSAlertSecondButtonReturn) { // != Discard Change
                // ツールバーから変更された場合のため、ツールバーアイテムの選択状態をリセット
                [[[self windowController] toolbarController] setSelectedEncoding:[self encoding]];
                return;
            }
        }
        
        NSError *error = nil;
        [self reinterpretWithEncoding:encoding error:&error];
        
        if (error) {
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert setAlertStyle:NSCriticalAlertStyle];
            
            NSBeep();
            [alert runModal];
        }
    }
    
    // ツールバーから変更された場合のため、ツールバーアイテムの選択状態をリセット
    [[[self windowController] toolbarController] setSelectedEncoding:[self encoding]];
}


// ------------------------------------------------------
/// 新しいテーマを適用
- (IBAction)changeTheme:(nullable id)sender
// ------------------------------------------------------
{
    NSString *name = [sender title];
    
    if ([name length] > 0) {
        [[self editor] setThemeWithName:name];
    }
}


// ------------------------------------------------------
/// 新しいシンタックスカラーリングスタイルを適用
- (IBAction)changeSyntaxStyle:(nullable id)sender
// ------------------------------------------------------
{
    NSString *name = [sender title];

    if ([name length] > 0) {
        [self doSetSyntaxStyle:name];
    }
}


// ------------------------------------------------------
/// IANA文字コード名を挿入する
- (IBAction)insertIANACharSetName:(nullable id)sender
// ------------------------------------------------------
{
    NSString *string = [self currentIANACharSetName];
    
    if (!string) { return; }
    
    NSTextView *textView = [[self editor] focusedTextView];
    if ([textView shouldChangeTextInRange:[textView selectedRange] replacementString:string]) {
        [textView replaceCharactersInRange:[textView selectedRange] withString:string];
        [textView didChangeText];
    }
}


// ------------------------------------------------------
/// IANA文字コード名を挿入する
- (IBAction)insertIANACharSetNameWithCharset:(nullable id)sender
// ------------------------------------------------------
{
    NSString *string = [self currentIANACharSetName];
    
    if (!string) { return; }
    
    NSString *insertionString = [NSString stringWithFormat:@"charset=\"%@\"", string];
    NSTextView *textView = [[self editor] focusedTextView];
    if ([textView shouldChangeTextInRange:[textView selectedRange] replacementString:insertionString]) {
        [textView replaceCharactersInRange:[textView selectedRange] withString:insertionString];
        [textView didChangeText];
    }
}


// ------------------------------------------------------
/// IANA文字コード名を挿入する
- (IBAction)insertIANACharSetNameWithEncoding:(nullable id)sender
// ------------------------------------------------------
{
    NSString *string = [self currentIANACharSetName];
    
    if (!string) { return; }
    
    NSString *insertionString = [NSString stringWithFormat:@"encoding=\"%@\"", string];
    NSTextView *textView = [[self editor] focusedTextView];
    if ([textView shouldChangeTextInRange:[textView selectedRange] replacementString:insertionString]) {
        [textView replaceCharactersInRange:[textView selectedRange] withString:insertionString];
        [textView didChangeText];
    }
}



#pragma mark Private Methods

// ------------------------------------------------------
/// return preferred file extension corresponding the current syntax style
- (NSString *)preferredExtension
// ------------------------------------------------------
{
    if ([self fileURL]) {
        return [[self fileURL] pathExtension];
        
    } else {
        NSString *styleName = [[self editor] syntaxStyleName];
        NSArray *extensions = [[CESyntaxManager sharedManager] extensionsForStyleName:styleName];
        
        return [extensions firstObject];
    }
}


// ------------------------------------------------------
/// editor を通じて syntax インスタンスをセット
- (void)setSyntaxStyleWithName:(NSString *)styleName coloring:(BOOL)doColoring
// ------------------------------------------------------
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultEnableSyntaxHighlightKey]) { return; }
    
    [[self editor] setSyntaxStyleWithName:styleName coloring:doColoring];
    
    // ツールバーのカラーリングポップアップの表示を更新、再カラーリング
    [[[self windowController] toolbarController] setSelectedSyntaxWithName:styleName];
}


// ------------------------------------------------------
/// ツールバーのエンコーディングメニュー、ステータスバー、インスペクタを更新
- (void)updateEncodingInToolbarAndInfo
// ------------------------------------------------------
{
    // ツールバーのエンコーディングメニューを更新
    [[[self windowController] toolbarController] setSelectedEncoding:[self encoding]];
    
    // ステータスバー、インスペクタを更新
    [[self windowController] updateModeInfoIfNeeded];
}


// ------------------------------------------------------
/// 改行コードをエディタに反映
- (void)applyLineEndingToView
// ------------------------------------------------------
{
    [[self windowController] updateModeInfoIfNeeded];
    [[self windowController] updateEditorInfoIfNeeded];
    [[[self windowController] toolbarController] setSelectedLineEnding:[self lineEnding]];
}


//------------------------------------------------------
/// データから指定エンコードで文字列を読み込み返す
- (nullable NSString *)stringFromData:(nonnull NSData *)data encoding:(NSStringEncoding)encoding xattrEncoding:(NSStringEncoding)xattrEncoding usedEncoding:(nonnull NSStringEncoding *)usedEncoding error:(NSError *__autoreleasing __nullable *)outError
//------------------------------------------------------
{
    NSString *string;
    
    if (encoding != CEAutoDetectEncoding) {  // interpret with specific encoding
        *usedEncoding = encoding;
        string = ([data length] == 0) ? @"" : [[NSString alloc] initWithData:data encoding:encoding];
        
    } else {  // Auto-Detection
        // try interpreting with xattr encoding
        if (xattrEncoding != NSNotFound) {
            // just trust xattr encoding if content is empty
            string = ([data length] == 0) ? @"" : [[NSString alloc] initWithData:data encoding:xattrEncoding];
            
            if (string) {
                *usedEncoding = xattrEncoding;
            }
        }
        
        if (!string) {
            // detect encoding from data
            string = [self stringFromData:data usedEncoding:usedEncoding error:outError];
        }
    }
    
    return string;
}


//------------------------------------------------------
/// データからエンコードを推測して文字列を得る
- (nullable NSString *)stringFromData:(nonnull NSData *)data usedEncoding:(nonnull NSStringEncoding *)usedEncoding error:(NSError *__autoreleasing __nullable *)outError
//------------------------------------------------------
{
    BOOL shouldSkipISO2022JP = NO;
    BOOL shouldSkipUTF8 = NO;
    BOOL shouldSkipUTF16 = NO;
    
    if ([data length] > 0) {
        // ISO 2022-JP / UTF-8 / UTF-16の判定は、「藤棚工房別棟 −徒然−」の
        // 「Cocoaで文字エンコーディングの自動判別プログラムを書いてみました」で公開されている
        // FJDDetectEncoding を参考にさせていただきました (2006-09-30)
        // http://blogs.dion.ne.jp/fujidana/archives/4169016.html
        
        // BOM 付き UTF-8 判定
        if (memchr([data bytes], *UTF8_BOM, 3) != NULL) {
            shouldSkipUTF8 = YES;
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (string) {
                *usedEncoding = NSUTF8StringEncoding;
                return string;
            }
            
        // UTF-16 判定
        } else if ((memchr([data bytes], 0xfffe, 2) != NULL) ||
                   (memchr([data bytes], 0xfeff, 2) != NULL))
        {
            shouldSkipUTF16 = YES;
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding];
            if (string) {
                *usedEncoding = NSUnicodeStringEncoding;
                return string;
            }
            
        // ISO 2022-JP 判定
        } else if (memchr([data bytes], 0x1b, [data length]) != NULL) {
            shouldSkipISO2022JP = YES;
            NSString *string = [[NSString alloc] initWithData:data encoding:NSISO2022JPStringEncoding];
            if (string) {
                *usedEncoding = NSISO2022JPStringEncoding;
                return string;
            }
        }
    }
    
    // try encodings in order from the top of the encoding list
    NSArray *encodings = [[NSUserDefaults standardUserDefaults] arrayForKey:CEDefaultEncodingListKey];
    
    for (NSNumber *encodingNumber in encodings) {
        NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding([encodingNumber unsignedIntegerValue]);
        
        if (((encoding == NSISO2022JPStringEncoding) && shouldSkipISO2022JP) ||
            ((encoding == NSUTF8StringEncoding) && shouldSkipUTF8) ||
            ((encoding == NSUnicodeStringEncoding) && shouldSkipUTF16))
        {
            continue;
        }
        
        NSString *string = [[NSString alloc] initWithData:data encoding:encoding];
        
        if (string) {
            // "charset=" や "encoding=" を読んでみて適正なエンコーディングが得られたら、そちらを優先
            NSStringEncoding scannedEncoding = [self scanEncodingDeclarationInString:string];
            
            if (scannedEncoding != NSNotFound && scannedEncoding != encoding) {
                NSString *tmpString = [[NSString alloc] initWithData:data encoding:scannedEncoding];
                if (tmpString) {
                    *usedEncoding = scannedEncoding;
                    return tmpString;
                }
            }
            
            *usedEncoding = encoding;
            return string;
        }
    }
    
    *usedEncoding = NSNotFound;
    return nil;
}


// ------------------------------------------------------
/// "charset=" "encoding="タグなどからエンコーディング定義を読み取る
- (NSStringEncoding)scanEncodingDeclarationInString:(NSString *)string
// ------------------------------------------------------
{
    // This method is based on Smultron's SMLTextPerformer.m by Peter Borg. (2005-08-10)
    // Smultron 2 was distributed on <http://smultron.sourceforge.net> under the terms of the BSD license.
    // Copyright (c) 2004-2006 Peter Borg
    
    // 参照しない設定になっているか、含まれている余地が無ければ中断
    if (![[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultReferToEncodingTagKey] || ([string length] < 9)) {
        return NSNotFound;
    }
    
    NSString *stringToScan = ([string length] > kMaxEncodingScanLength) ? [string substringToIndex:kMaxEncodingScanLength] : string;
    NSScanner *scanner = [NSScanner scannerWithString:stringToScan];  // 文書前方のみスキャンする
    NSCharacterSet *stopSet = [NSCharacterSet characterSetWithCharactersInString:@"\"\' </>\n\r"];
    NSString *scannedStr = nil;

    [scanner setCharactersToBeSkipped:[NSCharacterSet characterSetWithCharactersInString:@"\"\' "]];
    
    // find encoding with tag in order
    for (NSString *tag in @[@"charset=", @"encoding=", @"@charset", @"encoding:", @"coding:"]) {
        [scanner setScanLocation:0];
        while (![scanner isAtEnd]) {
            [scanner scanUpToString:tag intoString:nil];
            if ([scanner scanString:tag intoString:nil]) {
                if ([scanner scanUpToCharactersFromSet:stopSet intoString:&scannedStr]) {
                    break;
                }
            }
        }
        
        if (scannedStr) { break; }
    }
    
    if (!scannedStr) { return NSNotFound; }
    
    // 見つかったら NSStringEncoding に変換して返す
    CFStringEncoding cfEncoding = kCFStringEncodingInvalidId;
    // "Shift_JIS"だったら、kCFStringEncodingShiftJIS と kCFStringEncodingShiftJIS_X0213 の
    // 優先順位の高いものを取得する
    if ([[scannedStr uppercaseString] isEqualToString:@"SHIFT_JIS"]) {
        // （scannedStr をそのまま CFStringConvertIANACharSetNameToEncoding() で変換すると、大文字小文字を問わず
        // 「日本語（Shift JIS）」になってしまうため。IANA では大文字小文字を区別しないとしているのでこれはいいのだが、
        // CFStringConvertEncodingToIANACharSetName() では kCFStringEncodingShiftJIS と
        // kCFStringEncodingShiftJIS_X0213 がそれぞれ「SHIFT_JIS」「shift_JIS」と変換されるため、可逆性を持たせる
        // ための処理）
        NSArray *encodings = [[NSUserDefaults standardUserDefaults] arrayForKey:CEDefaultEncodingListKey];
        
        for (NSNumber *encodingNumber in encodings) {
            CFStringEncoding tmpCFEncoding = [encodingNumber unsignedLongValue];
            if ((tmpCFEncoding == kCFStringEncodingShiftJIS) ||
                (tmpCFEncoding == kCFStringEncodingShiftJIS_X0213))
            {
                cfEncoding = tmpCFEncoding;
                break;
            }
        }
    } else {
        // "Shift_JIS" 以外はそのまま変換する
        cfEncoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)scannedStr);
    }
    
    if (cfEncoding == kCFStringEncodingInvalidId) { return NSNotFound; }
    
    return CFStringConvertEncodingToNSStringEncoding(cfEncoding);
}


// ------------------------------------------------------
/// try extracting used language from the shebang line
- (nullable NSString *)scanLanguageFromShebangInString:(nonnull NSString *)string
// ------------------------------------------------------
{
    // get first line
    __block NSString *firstLine = nil;
    [string enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        firstLine = line;
        *stop = YES;
    }];
    
    // not found
    if (![firstLine hasPrefix:@"#!"]) { return nil; }
    
    // remove #! symbol
    firstLine = [firstLine stringByReplacingOccurrencesOfString:@"^#! *" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [firstLine length])];
    
    // find interpreter
    NSArray *components = [firstLine componentsSeparatedByString:@" "];
    NSString * path = components[0];
    NSString *interpreter = [[path componentsSeparatedByString:@"/"] lastObject];
    // use first arg if the path targets env
    if ([interpreter isEqualToString:@"env"]) {
        interpreter = components[1];
    }
    
    return interpreter;
}


// ------------------------------------------------------
/// IANA文字コード名を読み、設定されたエンコーディングと矛盾があれば警告する
- (BOOL)acceptsSaveDocumentWithIANACharSetName
// ------------------------------------------------------
{
    if ([self suppressesIANACharsetConflictAlert]) { return YES; }
    
    NSError *error;
    [self checkSavingSafetyWithIANACharSetNameForString:[self stringForSave] encoding:[self encoding] error:&error];
    
    if (error) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert setShowsSuppressionButton:YES];
        [[alert suppressionButton] setTitle:NSLocalizedString(@"Do not show this warning for this document again", nil)];
        
        NSInteger result = [alert runModal];
        // do not show the alert in this document again
        if ([[alert suppressionButton] state] == NSOnState) {
            [self setSuppressesIANACharsetConflictAlert:YES];
        }
        
        switch (result) {
            case NSAlertFirstButtonReturn:  // == Cancel
                return NO;
                
            case NSAlertSecondButtonReturn:  // == Continue Saving
                return YES;
        }
    }
    
    return YES;
}


// ------------------------------------------------------
/// ファイル保存前のエンコーディング変換チェック、ユーザに承認を求める
- (BOOL)acceptsSaveDocumentToConvertEncoding
// ------------------------------------------------------
{
    NSError *error;
    [self checkSavingSafetyForConvertingString:[self stringForSave] encoding:[self encoding] error:&error];
    
    if (error) {
        NSAlert *alert = [NSAlert alertWithError:error];
        
        NSInteger result = [alert runModal];
        switch (result) {
            case NSAlertFirstButtonReturn:  // == Show Incompatible Chars
                [[self windowController] showIncompatibleCharList];
                return NO;
                
            case NSAlertSecondButtonReturn:  // == Save
                return YES;
                
            case NSAlertThirdButtonReturn:  // == Cancel
                return NO;
        }
    }
    
    return YES;
}


// ------------------------------------------------------
/// 書類内のIANA文字コード名と設定されたエンコーディングの矛盾をチェック
- (BOOL)checkSavingSafetyWithIANACharSetNameForString:(NSString *)string encoding:(NSStringEncoding)encoding error:(NSError *__autoreleasing __nullable *)outError
// ------------------------------------------------------
{
    NSStringEncoding IANACharSetEncoding = [self scanEncodingDeclarationInString:string];
    
    const NSStringEncoding ShiftJIS = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS);
    const NSStringEncoding X0213 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS_X0213);
    
    if ((IANACharSetEncoding != NSNotFound) &&
        (IANACharSetEncoding != encoding) &&
        !(((IANACharSetEncoding == ShiftJIS) || (IANACharSetEncoding == X0213)) &&
          ((encoding == ShiftJIS) || (encoding == X0213))))
    {
        // (Caution needed on Shift-JIS. See `scanCharsetOrEncodingFromString:` for details.)
        
        if (outError) {
            NSString *encodingName = [NSString localizedNameOfStringEncoding:encoding];
            NSString *IANAName = [NSString localizedNameOfStringEncoding:IANACharSetEncoding];
            
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"The encoding is “%@”, but the IANA charset name in text is “%@”.", nil), encodingName, IANAName],
                                       NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Do you want to continue processing?", nil),
                                       NSLocalizedRecoveryOptionsErrorKey: @[NSLocalizedString(@"Cancel", nil),
                                                                             NSLocalizedString(@"Continue Saving", nil)],
                                       NSStringEncodingErrorKey: @(encoding),
                                       };
            
            *outError = [NSError errorWithDomain:CEErrorDomain code:CEIANACharsetNameConflictError userInfo:userInfo];
        }
        
        return NO;
    }
    
    return YES;
}


// ------------------------------------------------------
/// ファイル保存前のエンコーディング変換チェック
- (BOOL)checkSavingSafetyForConvertingString:(NSString *)string encoding:(NSStringEncoding)encoding error:(NSError *__autoreleasing __nullable *)outError
// ------------------------------------------------------
{
    // エンコーディングを見て、半角円マークを変換しておく
    NSString *newString = [self convertCharacterString:string encoding:encoding];
    
    if (![newString canBeConvertedToEncoding:encoding]) {
        if (outError) {
            NSString *encodingName = [NSString localizedNameOfStringEncoding:encoding];
            
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"The characters would have to be changed or deleted in saving as “%@”.", nil), encodingName],
                                       NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Do you want to continue processing?", nil),
                                       NSLocalizedRecoveryOptionsErrorKey: @[NSLocalizedString(@"Show Incompatible Chars", nil),
                                                                             NSLocalizedString(@"Save Available Strings", nil),
                                                                             NSLocalizedString(@"Cancel", nil)],
                                       NSStringEncodingErrorKey: @(encoding),
                                       };
            *outError = [NSError errorWithDomain:CEErrorDomain code:CEUnconvertibleCharactersError userInfo:userInfo];
        }
        
        return NO;
    }
    
    return YES;
}


// ------------------------------------------------------
/// 半角円マークを使えないエンコードの時はバックスラッシュに変換した文字列を返す
- (NSString *)convertCharacterString:(NSString *)string encoding:(NSStringEncoding)encoding
// ------------------------------------------------------
{
    if (([string length] > 0) && [CEUtils isInvalidYenEncoding:encoding]) {
        return [string stringByReplacingOccurrencesOfString:[NSString stringWithCharacters:&kYenMark length:1]
                                                 withString:@"\\"];
    }
    
    return string;
}


// ------------------------------------------------------
/// エンコードを変更するアクションのRedo登録
- (void)redoSetEncoding:(NSStringEncoding)encoding updateDocument:(BOOL)updateDocument askLossy:(BOOL)askLossy lossy:(BOOL)lossy asActionName:(nullable NSString *)actionName
// ------------------------------------------------------
{
    [[[self undoManager] prepareWithInvocationTarget:self] doSetEncoding:encoding updateDocument:updateDocument
                                                                askLossy:askLossy lossy:lossy asActionName:actionName];
}


// ------------------------------------------------------
/// 改行コードを変更するアクションのRedo登録
- (void)redoSetLineEnding:(CENewLineType)lineEnding
// ------------------------------------------------------
{
    [[[self undoManager] prepareWithInvocationTarget:self] doSetLineEnding:lineEnding];
}


// ------------------------------------------------------
/// 書き込み禁止アラートを表示
- (void)showNotWritableAlert
// ------------------------------------------------------
{
    if ([self isWritable] || [self didAlertNotWritable]) { return; }
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultShowAlertForNotWritableKey]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"The file is not writable.", nil)];
        [alert setInformativeText:NSLocalizedString(@"You may not be able to save your changes, but you will be able to save a copy somewhere else.", nil)];
        
        [alert beginSheetModalForWindow:[self windowForSheet]
                          modalDelegate:self
                         didEndSelector:NULL
                            contextInfo:NULL];
    }
    [self setDidAlertNotWritable:YES];
}


// ------------------------------------------------------
/// notify about external file update
- (void)notifyExternalFileUpdate
// ------------------------------------------------------
{
    // rise a flag
    [self setNeedsShowUpdateAlertWithBecomeKey:YES];
    
    if ([NSApp isActive]) {
        // display dialog
        [self showUpdatedByExternalProcessAlert];
        
    } else if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultNotifyEditByAnotherKey]) {
        // let application icon in Dock jump
        [NSApp requestUserAttention:NSInformationalRequest];
    }
}


// ------------------------------------------------------
/// 外部プロセスによって更新されたことをシート／ダイアログで通知
- (void)showUpdatedByExternalProcessAlert
// ------------------------------------------------------
{
    if (![self needsShowUpdateAlertWithBecomeKey]) { return; } // 表示フラグが立っていなければ、もどる
    
    NSString *messageText;
    if ([self isDocumentEdited]) {
        messageText = @"The file has been modified by another application. There are also unsaved changes in CotEditor.";
    } else {
        messageText = @"The file has been modified by another application.";
        [self updateChangeCount:NSChangeDone]; // ダーティーフラグを立てる
    }
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(messageText, nil)];
    [alert setInformativeText:NSLocalizedString(@"Do you want to keep CotEditor's edition or update to the modified edition?", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Keep CotEditor's Edition", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Update", nil)];
    
    // シートが表示中でなければ、表示
    if ([[self windowForSheet] attachedSheet] == nil) {
        [self setRevertingForExternalFileUpdate:YES];
        [[self windowForSheet] orderFront:nil]; // 後ろにあるウィンドウにシートを表示させると不安定になることへの対策
        [alert beginSheetModalForWindow:[self windowForSheet]
                          modalDelegate:self
                         didEndSelector:@selector(alertForModByAnotherProcessDidEnd:returnCode:contextInfo:)
                            contextInfo:NULL];
        
    } else if ([self isRevertingForExternalFileUpdate]) {
        // （同じ外部プロセスによる変更通知アラートシートを表示中の時は、なにもしない）
        
        // 既にシートが出ている時はダイアログで表示
    } else {
        [self setRevertingForExternalFileUpdate:YES];
        [[self windowForSheet] orderFront:nil]; // 後ろにあるウィンドウにシートを表示させると不安定になることへの対策
        NSInteger result = [alert runModal]; // アラート表示
        [self alertForModByAnotherProcessDidEnd:alert returnCode:result contextInfo:NULL];
    }
}


// ------------------------------------------------------
/// 外部プロセスによる変更の通知アラートが閉じた
- (void)alertForModByAnotherProcessDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
// ------------------------------------------------------
{
    if (returnCode == NSAlertSecondButtonReturn) { // == Revert
        [self revertToContentsOfURL:[self fileURL] ofType:[self fileType] error:nil];
    }
    [self setRevertingForExternalFileUpdate:NO];
    [self setNeedsShowUpdateAlertWithBecomeKey:NO];
}

@end
