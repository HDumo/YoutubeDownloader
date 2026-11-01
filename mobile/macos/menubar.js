// Menu-bar helper for YouTube Downloader (macOS). Started by the server with: osascript -l JavaScript menubar.js <port>
// It only shows an icon and a menu; every click is printed as one word on stdout and the server acts on it:
//   open | pause | resume | quit
ObjC.import('Cocoa');

function say(word) {
  var data = $(word + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(data);
}

ObjC.registerSubclass({
  name: 'YTDLMenuHandler',
  superclass: 'NSObject',
  methods: {
    'menuAction:': {
      types: ['void', ['id']],
      implementation: function (sender) {
        say(ObjC.unwrap(sender.representedObject));
      }
    }
  }
});

var app = $.NSApplication.sharedApplication;
app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);     // no Dock icon

var statusItem = $.NSStatusBar.systemStatusBar.statusItemWithLength($.NSVariableStatusItemLength);
var shown = false;
try {                                                                  // a proper icon on macOS 11+
  var img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('arrow.down.circle', 'YouTube Downloader');
  if (img && !img.isNil()) { img.setTemplate(true); statusItem.button.setImage(img); shown = true; }
} catch (e) { }
if (!shown) { statusItem.button.setTitle($('⬇')); }               // fall back to a text arrow
statusItem.button.setToolTip($('YouTube Downloader'));

var handler = $.YTDLMenuHandler.alloc.init;
var menu = $.NSMenu.alloc.initWithTitle($('YouTube Downloader'));

function addItem(title, word) {
  var item = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent($(title), 'menuAction:', $(''));
  item.setTarget(handler);
  item.setRepresentedObject($(word));
  menu.addItem(item);
}

addItem('Open YouTube Downloader', 'open');
menu.addItem($.NSMenuItem.separatorItem);
addItem('Pause downloads', 'pause');
addItem('Resume downloads', 'resume');
menu.addItem($.NSMenuItem.separatorItem);
addItem('Quit YouTube Downloader', 'quit');
statusItem.setMenu(menu);

app.run;
