//
//  DTHTMLAttributedStringBuilder.m
//  DTCoreText
//
//  Created by Oliver Drobnik on 21.01.12.
//  Copyright (c) 2012 Drobnik.com. All rights reserved.
//

#import "DTCoreText.h"
#import "DTHTMLAttributedStringBuilder.h"
#import "DTFoundation.h"

#import "DTHTMLElementText.h"
#import "DTHTMLElementBR.h"
#import "DTHTMLElementStylesheet.h"

@interface DTHTMLAttributedStringBuilder ()

- (void)_registerTagStartHandlers;
- (void)_registerTagEndHandlers;

@end


@implementation DTHTMLAttributedStringBuilder
{
	NSData *_data;
	NSDictionary *_options;
	
	// settings for parsing
	CGFloat _textScale;
	DTColor *_defaultLinkColor;
	DTCSSStylesheet *_globalStyleSheet;
	NSURL *_baseURL;
	DTCoreTextFontDescriptor *_defaultFontDescriptor;
	DTCoreTextParagraphStyle *_defaultParagraphStyle;
	
	// parsing state, accessed from inside blocks
	NSMutableAttributedString *_tmpString;
	
	// GCD
	dispatch_queue_t _stringAssemblyQueue;
	dispatch_group_t _stringAssemblyGroup;
	dispatch_queue_t _stringParsingQueue;
	dispatch_group_t _stringParsingGroup;
	
	// lookup table for blocks that deal with begin and end tags
	NSMutableDictionary *_tagStartHandlers;
	NSMutableDictionary *_tagEndHandlers;
	
	DTHTMLAttributedStringBuilderWillFlushCallback _willFlushCallback;
	
	// new parsing
	DTHTMLElement *_rootNode;
	DTHTMLElement *_bodyElement;
	DTHTMLElement *_currentTag;
	NSMutableArray *_outputQueue;
	
	DTHTMLElement *_defaultTag; // root node inherits these defaults
	BOOL _shouldKeepDocumentNodeTree;
}

- (id)initWithHTML:(NSData *)data options:(NSDictionary *)options documentAttributes:(NSDictionary **)docAttributes
{
	self = [super init];
	if (self)
	{
		_data = data;
		_options = options;
		
		// documentAttributes ignored for now
		
		//GCD setup
		_stringAssemblyQueue = dispatch_queue_create("DTHTMLAttributedStringBuilder", 0);
		_stringAssemblyGroup = dispatch_group_create();
		_stringParsingQueue = dispatch_queue_create("DTHTMLAttributedStringBuilderParser", 0);
		_stringParsingGroup = dispatch_group_create();
	}
	
	return self;
}

- (void)dealloc
{
#if TARGET_API_MAC_OSX
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1080
	dispatch_release(_stringAssemblyQueue);
	dispatch_release(_stringAssemblyGroup);
	dispatch_release(_stringParsingQueue);
	dispatch_release(_stringParsingGroup);
#endif
#endif
}

- (BOOL)_buildString
{
	// only with valid data
	if (![_data length])
	{
		return NO;
	}
	
	// register default handlers
	[self _registerTagStartHandlers];
	[self _registerTagEndHandlers];
	
 	// Specify the appropriate text encoding for the passed data, default is UTF8
	NSString *textEncodingName = [_options objectForKey:NSTextEncodingNameDocumentOption];
	NSStringEncoding encoding = NSUTF8StringEncoding; // default
	
	if (textEncodingName)
	{
		CFStringEncoding cfEncoding = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)textEncodingName);
		encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding);
	}
	
	// custom option to use iOS 6 attributes if running on iOS 6
	if ([[_options objectForKey:DTUseiOS6Attributes] boolValue])
	{
		if (![DTVersion osVersionIsLessThen:@"6.0"])
		{
			___useiOS6Attributes = YES;
		}
		else
		{
			___useiOS6Attributes = NO;
		}
	}
	else
	{
		// default is not to use them because many features are not supported
		___useiOS6Attributes = NO;
	}
	
	// custom option to scale text
	_textScale = [[_options objectForKey:NSTextSizeMultiplierDocumentOption] floatValue];
	if (!_textScale)
	{
		_textScale = 1.0f;
	}
	
	// use baseURL from options if present
	_baseURL = [_options objectForKey:NSBaseURLDocumentOption];
	
	// the combined style sheet for entire document
	_globalStyleSheet = [[DTCSSStylesheet defaultStyleSheet] copy];
	
	// do we have a default style sheet passed as option?
	DTCSSStylesheet *defaultStylesheet = [_options objectForKey:DTDefaultStyleSheet];
	if (defaultStylesheet)
	{
		// merge the default styles to the combined style sheet
		[_globalStyleSheet mergeStylesheet:defaultStylesheet];
	}
	
	// for performance reasons we will return this mutable string
	_tmpString = [[NSMutableAttributedString alloc] init];
	
	// base tag with font defaults
	_defaultFontDescriptor = [[DTCoreTextFontDescriptor alloc] initWithFontAttributes:nil];
	_defaultFontDescriptor.pointSize = 12.0f * _textScale;
	
	NSString *defaultFontFamily = [_options objectForKey:DTDefaultFontFamily];
	if (defaultFontFamily)
	{
		_defaultFontDescriptor.fontFamily = defaultFontFamily;
	}
	else
	{
		_defaultFontDescriptor.fontFamily = @"Times New Roman";
	}
	
	_defaultLinkColor = [_options objectForKey:DTDefaultLinkColor];
	
	if (_defaultLinkColor)
	{
		if ([_defaultLinkColor isKindOfClass:[NSString class]])
		{
			// convert from string to color
			_defaultLinkColor = [DTColor colorWithHTMLName:(NSString *)_defaultLinkColor];
		}
		
		// get hex code for the passed color
		NSString *colorHex = [_defaultLinkColor htmlHexString];
		
		// overwrite the style
		NSString *styleBlock = [NSString stringWithFormat:@"a {color:#%@;}", colorHex];
		[_globalStyleSheet parseStyleBlock:styleBlock];
	}
	
	// default is to have A underlined
	NSNumber *linkDecorationDefault = [_options objectForKey:DTDefaultLinkDecoration];
	
	if (linkDecorationDefault)
	{
		if (![linkDecorationDefault boolValue])
		{
			// remove default decoration
			[_globalStyleSheet parseStyleBlock:@"a {text-decoration:none;}"];
		}
	}
	
	// default paragraph style
	_defaultParagraphStyle = [DTCoreTextParagraphStyle defaultParagraphStyle];
	
	NSNumber *defaultLineHeightMultiplierNum = [_options objectForKey:DTDefaultLineHeightMultiplier];
	
	if (defaultLineHeightMultiplierNum)
	{
		CGFloat defaultLineHeightMultiplier = [defaultLineHeightMultiplierNum floatValue];
		_defaultParagraphStyle.lineHeightMultiple = defaultLineHeightMultiplier;
	}
	
	NSNumber *defaultTextAlignmentNum = [_options objectForKey:DTDefaultTextAlignment];
	
	if (defaultTextAlignmentNum)
	{
		_defaultParagraphStyle.alignment = (CTTextAlignment)[defaultTextAlignmentNum integerValue];
	}
	
	NSNumber *defaultFirstLineHeadIndent = [_options objectForKey:DTDefaultFirstLineHeadIndent];
	if (defaultFirstLineHeadIndent)
	{
		_defaultParagraphStyle.firstLineHeadIndent = [defaultFirstLineHeadIndent integerValue];
	}
	
	NSNumber *defaultHeadIndent = [_options objectForKey:DTDefaultHeadIndent];
	if (defaultHeadIndent)
	{
		_defaultParagraphStyle.headIndent = [defaultHeadIndent integerValue];
	}
	
	NSNumber *defaultListIndent = [_options objectForKey:DTDefaultListIndent];
	if (defaultListIndent)
	{
		_defaultParagraphStyle.listIndent = [defaultListIndent integerValue];
	}
	
	_defaultTag = [[DTHTMLElement alloc] init];
	_defaultTag.fontDescriptor = _defaultFontDescriptor;
	_defaultTag.paragraphStyle = _defaultParagraphStyle;
	_defaultTag.textScale = _textScale;
	
	id defaultColor = [_options objectForKey:DTDefaultTextColor];
	if (defaultColor)
	{
		if ([defaultColor isKindOfClass:[DTColor class]])
		{
			// already a DTColor
			_defaultTag.textColor = defaultColor;
		}
		else
		{
			// need to convert first
			_defaultTag.textColor = [DTColor colorWithHTMLName:defaultColor];
		}
	}
	
	_outputQueue = [[NSMutableArray alloc] init];
	
	// create a parser
	DTHTMLParser *parser = [[DTHTMLParser alloc] initWithData:_data encoding:encoding];
	parser.delegate = (id)self;
	
	__block BOOL result;
	dispatch_group_async(_stringParsingGroup, _stringParsingQueue, ^{ result = [parser parse]; });
	
	// wait until all string assembly is complete
	dispatch_group_wait(_stringParsingGroup, DISPATCH_TIME_FOREVER);
	dispatch_group_wait(_stringAssemblyGroup, DISPATCH_TIME_FOREVER);
	
	// clean up handlers because they retained self
	_tagStartHandlers = nil;
	_tagEndHandlers = nil;
	
	return result;
}

- (NSAttributedString *)generatedAttributedString
{
	if (!_tmpString)
	{
		[self _buildString];
	}
	
	return _tmpString;
}

#pragma mark GCD

- (void)_registerTagStartHandlers
{
	if (_tagStartHandlers)
	{
		return;
	}
	
	_tagStartHandlers = [[NSMutableDictionary alloc] init];

	
	void (^blockquoteBlock)(void) = ^
	{
		_currentTag.paragraphStyle.headIndent += 25.0 * _textScale;
		_currentTag.paragraphStyle.firstLineHeadIndent = _currentTag.paragraphStyle.headIndent;
		_currentTag.paragraphStyle.paragraphSpacing = _defaultFontDescriptor.pointSize;
	};
	
	[_tagStartHandlers setObject:[blockquoteBlock copy] forKey:@"blockquote"];
	
	
	void (^aBlock)(void) = ^
	{
		if (_currentTag.isColorInherited || !_currentTag.textColor)
		{
			_currentTag.textColor = _defaultLinkColor;
			_currentTag.isColorInherited = NO;
		}
		
		// remove line breaks and whitespace in links
		NSString *cleanString = [[_currentTag attributeForKey:@"href"] stringByReplacingOccurrencesOfString:@"\n" withString:@""];
		cleanString = [cleanString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		
		NSURL *link = [NSURL URLWithString:cleanString];
		
		// deal with relative URL
		if (![link scheme])
		{
			if ([cleanString length])
			{
				link = [NSURL URLWithString:cleanString relativeToURL:_baseURL];
				
				if (!link)
				{
					// NSURL did not like the link, so let's encode it
					cleanString = [cleanString stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
					
					link = [NSURL URLWithString:cleanString relativeToURL:_baseURL];
				}
			}
			else
			{
				link = _baseURL;
			}
		}
		
		_currentTag.link = link;
		
		// the name attribute of A becomes an anchor
		_currentTag.anchorName = [_currentTag attributeForKey:@"name"];
	};
	
	[_tagStartHandlers setObject:[aBlock copy] forKey:@"a"];
	
	
	void (^liBlock)(void) = ^
	{
		_currentTag.paragraphStyle.paragraphSpacing = 0;
		
		DTCSSListStyle *listStyle = [_currentTag.paragraphStyle.textLists lastObject];
		
		if (listStyle.type != DTCSSListStyleTypeNone)
		{
			// first tab is to right-align bullet, numbering against
			CGFloat tabOffset = _currentTag.paragraphStyle.headIndent - 5.0f*_textScale;
			[_currentTag.paragraphStyle addTabStopAtPosition:tabOffset alignment:kCTRightTextAlignment];
		}
		
		// second tab is for the beginning of first line after bullet
		[_currentTag.paragraphStyle addTabStopAtPosition:_currentTag.paragraphStyle.headIndent alignment:	kCTLeftTextAlignment];
	};
	
	[_tagStartHandlers setObject:[liBlock copy] forKey:@"li"];
	
	
	void (^listBlock)(void) = ^
	{
		_currentTag.paragraphStyle.firstLineHeadIndent = _currentTag.paragraphStyle.headIndent;
		_currentTag.paragraphStyle.headIndent += _currentTag.paragraphStyle.listIndent;
		
		// create the appropriate list style from CSS
		NSDictionary *styles = [_currentTag styles];
		DTCSSListStyle *newListStyle = [[DTCSSListStyle alloc] initWithStyles:styles];
		
		// append this list style to the current paragraph style text lists
		NSMutableArray *textLists = [_currentTag.paragraphStyle.textLists mutableCopy];
		if (!textLists)
		{
			textLists = [NSMutableArray array];
		}
		
		[textLists addObject:newListStyle];
		
		// workaround for different styles on stacked lists
		if ([textLists count]>1) // not necessary for first
		{
			// find out if each list is ordered or unordered
			NSMutableArray *tmpArray = [NSMutableArray array];
			for (DTCSSListStyle *oneList in textLists)
			{
				if ([oneList isOrdered])
				{
					[tmpArray addObject:@"ol"];
				}
				else
				{
					[tmpArray addObject:@"ul"];
				}
			}
			
			// build a CSS selector
			NSString *selector = [tmpArray componentsJoinedByString:@" "];
			
			// find style
			NSDictionary *style = [[_globalStyleSheet styles] objectForKey:selector];
			
			if (style)
			{
				[newListStyle updateFromStyleDictionary:style];
			}
		}
		
		_currentTag.paragraphStyle.textLists = textLists;
	};
	
	[_tagStartHandlers setObject:[listBlock copy] forKey:@"ul"];
	[_tagStartHandlers setObject:[listBlock copy] forKey:@"ol"];
	
	void (^h1Block)(void) = ^
	{
		_currentTag.headerLevel = 1;
	};
	[_tagStartHandlers setObject:[h1Block copy] forKey:@"h1"];
	
	void (^h2Block)(void) = ^
	{
		_currentTag.headerLevel = 2;
	};
	[_tagStartHandlers setObject:[h2Block copy] forKey:@"h2"];
	
	
	void (^h3Block)(void) = ^
	{
		_currentTag.headerLevel = 3;
	};
	[_tagStartHandlers setObject:[h3Block copy] forKey:@"h3"];
	
	
	void (^h4Block)(void) = ^
	{
		_currentTag.headerLevel = 4;
	};
	[_tagStartHandlers setObject:[h4Block copy] forKey:@"h4"];
	
	
	void (^h5Block)(void) = ^
	{
		_currentTag.headerLevel = 5;
	};
	[_tagStartHandlers setObject:[h5Block copy] forKey:@"h5"];
	
	
	void (^h6Block)(void) = ^
	{
		_currentTag.headerLevel = 6;
	};
	[_tagStartHandlers setObject:[h6Block copy] forKey:@"h6"];
	
	
	void (^fontBlock)(void) = ^
	{
		NSInteger size = [[_currentTag attributeForKey:@"size"] intValue];
		
		switch (size)
		{
			case 1:
				_currentTag.fontDescriptor.pointSize = _textScale * 9.0f;
				break;
			case 2:
				_currentTag.fontDescriptor.pointSize = _textScale * 10.0f;
				break;
			case 4:
				_currentTag.fontDescriptor.pointSize = _textScale * 14.0f;
				break;
			case 5:
				_currentTag.fontDescriptor.pointSize = _textScale * 18.0f;
				break;
			case 6:
				_currentTag.fontDescriptor.pointSize = _textScale * 24.0f;
				break;
			case 7:
				_currentTag.fontDescriptor.pointSize = _textScale * 37.0f;
				break;
			case 3:
			default:
				_currentTag.fontDescriptor.pointSize = _defaultFontDescriptor.pointSize;
				break;
		}
		
		NSString *face = [_currentTag attributeForKey:@"face"];
		
		if (face)
		{
			_currentTag.fontDescriptor.fontName = face;
			
			// face usually invalidates family
			_currentTag.fontDescriptor.fontFamily = nil;
		}
		
		NSString *color = [_currentTag attributeForKey:@"color"];
		
		if (color)
		{
			_currentTag.textColor = [DTColor colorWithHTMLName:color];
		}
	};
	
	[_tagStartHandlers setObject:[fontBlock copy] forKey:@"font"];
	
	
	void (^pBlock)(void) = ^
	{
		_currentTag.paragraphStyle.firstLineHeadIndent = _currentTag.paragraphStyle.headIndent + _defaultParagraphStyle.firstLineHeadIndent;
	};
	
	[_tagStartHandlers setObject:[pBlock copy] forKey:@"p"];
}

- (void)_registerTagEndHandlers
{
	if (_tagEndHandlers)
	{
		return;
	}
	
	_tagEndHandlers = [[NSMutableDictionary alloc] init];
	
	
	void (^styleBlock)(void) = ^
	{
		DTCSSStylesheet *localSheet = [(DTHTMLElementStylesheet *)_currentTag stylesheet];
		[_globalStyleSheet mergeStylesheet:localSheet];
	};
	
	[_tagEndHandlers setObject:[styleBlock copy] forKey:@"style"];
}

#pragma mark DTHTMLParser Delegate

- (void)parser:(DTHTMLParser *)parser didStartElement:(NSString *)elementName attributes:(NSDictionary *)attributeDict
{
	dispatch_group_async(_stringAssemblyGroup, _stringAssemblyQueue, ^{
		DTHTMLElement *newNode = [DTHTMLElement elementWithName:elementName attributes:attributeDict options:_options];
		
		if (_currentTag)
		{
			// inherit stuff
			[newNode inheritAttributesFromElement:_currentTag];
			
			// add as new child of current node
			[_currentTag addChildNode:newNode];
			
			// remember body node
			if (!_bodyElement && [newNode.name isEqualToString:@"body"])
			{
				_bodyElement = newNode;
			}
		}
		else
		{
			// might be first node ever
			if (!_rootNode)
			{
				_rootNode = newNode;
				
				[_rootNode inheritAttributesFromElement:_defaultTag];
			}
		}
		
		// apply style from merged style sheet
		NSDictionary *mergedStyles = [_globalStyleSheet mergedStyleDictionaryForElement:newNode];
		if (mergedStyles)
		{
			[newNode applyStyleDictionary:mergedStyles];
		}
		
		_currentTag = newNode;
		
		// find block to execute for this tag if any
		void (^tagBlock)(void) = [_tagStartHandlers objectForKey:elementName];
		
		if (tagBlock)
		{
			tagBlock();
		}
	});
}

- (void)parser:(DTHTMLParser *)parser didEndElement:(NSString *)elementName
{
	dispatch_group_async(_stringAssemblyGroup, _stringAssemblyQueue, ^{
		// output the element if it is direct descendant of body tag, or close of body in case there are direct text nodes
		
		// find block to execute for this tag if any
		void (^tagBlock)(void) = [_tagEndHandlers objectForKey:elementName];
		
		if (tagBlock)
		{
			tagBlock();
		}
		
		if (_currentTag.displayStyle != DTHTMLElementDisplayStyleNone)
		{
			if (_currentTag == _bodyElement || _currentTag.parentElement == _bodyElement)
			{
				// has children that have not been output yet
				if ([_currentTag needsOutput])
				{
					// caller gets opportunity to modify tag before it is written
					if (_willFlushCallback)
					{
						_willFlushCallback(_currentTag);
					}
					
					NSAttributedString *nodeString = [_currentTag attributedString];
					
					if (nodeString)
					{
						// if this is a block element then we need a paragraph break before it
						if (_currentTag.displayStyle != DTHTMLElementDisplayStyleInline)
						{
							if ([_tmpString length] && ![[_tmpString string] hasSuffix:@"\n"])
							{
								// trim off whitespace
								while ([[_tmpString string] hasSuffixCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]])
								{
									[_tmpString deleteCharactersInRange:NSMakeRange([_tmpString length]-1, 1)];
								}
								
								[_tmpString appendString:@"\n"];
							}
						}
						
						
						[_tmpString appendAttributedString:nodeString];
						_currentTag.didOutput = YES;
						
						if (!_shouldKeepDocumentNodeTree)
						{
							// we don't need the children any more
							[_currentTag removeAllChildNodes];
						}
					}
				}
			}
		}
		
		// go back up a level
		_currentTag = [_currentTag parentElement];
	});
}

- (void)parser:(DTHTMLParser *)parser foundCharacters:(NSString *)string
{
	
	dispatch_group_async(_stringAssemblyGroup, _stringAssemblyQueue, ^{
		NSAssert(_currentTag, @"Cannot add text node without a current node");
		
		if ([string isIgnorableWhitespace])
		{
			// ignore whitespace as first element
			if (![_currentTag.childNodes count])
			{
				return;
			}
			
			// ignore whitespace following a block element
			DTHTMLElement *previousTag = [_currentTag.childNodes lastObject];
			
			if (previousTag.displayStyle != DTHTMLElementDisplayStyleInline)
			{
				return;
			}
			
			// ignore whitespace following a BR
			if ([previousTag isKindOfClass:[DTHTMLElementBR class]])
			{
				return;
			}
		}
		
		// adds a text node to the current node
		DTHTMLElementText *textNode = [[DTHTMLElementText alloc] init];
		textNode.text = string;
		
		[textNode inheritAttributesFromElement:_currentTag];
		
		// need to transfer Apple Converted Space tag to text node
		textNode.containsAppleConvertedSpace = _currentTag.containsAppleConvertedSpace;
		
		// text directly contained in body needs to be output right away
		if (_currentTag == _bodyElement)
		{
			[_tmpString appendAttributedString:[textNode attributedString]];
			_currentTag.didOutput = YES;
			
			// only add it to current tag if we need it
			if (_shouldKeepDocumentNodeTree)
			{
				[_currentTag addChildNode:textNode];
			}
			
			return;
		}
		
		// save it for later output
		[_currentTag addChildNode:textNode];
	});
}

- (void)parser:(DTHTMLParser *)parser foundCDATA:(NSData *)CDATABlock
{
	dispatch_group_async(_stringAssemblyGroup, _stringAssemblyQueue, ^{
		NSAssert(_currentTag, @"Cannot add text node without a current node");
		
		NSString *styleBlock = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
		
		// adds a text node to the current node
		DTHTMLParserTextNode *textNode = [[DTHTMLParserTextNode alloc] initWithCharacters:styleBlock];
		
		[_currentTag addChildNode:textNode];
	});
}

- (void)parserDidEndDocument:(DTHTMLParser *)parser
{
	dispatch_group_async(_stringAssemblyGroup, _stringAssemblyQueue, ^{
		NSAssert(!_currentTag, @"Something went wrong, at end of document there is still an open node");
		
		// trim off white space at end
		while ([[_tmpString string] hasSuffixCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]])
		{
			[_tmpString deleteCharactersInRange:NSMakeRange([_tmpString length]-1, 1)];
		}
	});
}

#pragma mark Properties

@synthesize willFlushCallback = _willFlushCallback;
@synthesize shouldKeepDocumentNodeTree = _shouldKeepDocumentNodeTree;

@end
