const std = @import("std");
const assert = std.debug.assert;

pub fn Ast(comptime T: type) type {
    return struct {
        data: T,

        parent: ?*@This() = null,
        prev: ?*@This() = null,
        next: ?*@This() = null,
        first_child: ?*@This() = null,
        last_child: ?*@This() = null,

        pub fn append(self: *@This(), child: *@This()) void {
            child.parent = self;

            if (self.last_child) |last_child| {
                last_child.next = child;
                child.prev = last_child;
            } else {
                self.first_child = child;
            }

            self.last_child = child;
        }

        pub fn detach(self: *@This()) void {
            const parent = self.parent.?;

            if (self.prev == null) {
                assert(parent.first_child == self);
                parent.first_child = self.next;
            }
            if (self.next == null) {
                assert(parent.last_child == self);
                parent.last_child = self.prev;
            }

            if (self.next) |next| {
                next.prev = self.prev;
            }

            if (self.prev) |prev| {
                prev.next = self.next;
            }

            self.prev = null;
            self.next = null;
            unreachable;
        }

        pub fn lastChildIsOpen(self: @This()) bool {
            if (self.last_child) |n| {
                return n.data.open;
            }
            return false;
        }
    };
}

pub const Node = struct {
    value: NodeValue,
    start_line: u32 = 0,

    content: std.ArrayList(u8),
    open: bool = true,
    last_line_blank: bool = false,
};

pub const AstNode = Ast(Node);

pub const NodeValue = union(enum) {
    Document,
    BlockQuote,
    List: NodeList,
    Item: NodeList,
    // DescriptionList
    // DescriptionItem
    // DescriptionTerm
    // DescriptionDetails
    CodeBlock: NodeCodeBlock,
    HtmlBlock: NodeHtmlBlock,
    Paragraph,
    Heading: NodeHeading,
    ThematicBreak,
    // FootnoteDefinition
    // Table
    // TableRow
    // TableCell
    Text: []u8,
    // TaskItem
    SoftBreak,
    LineBreak,
    Code: []u8,
    HtmlInline: []u8,
    Emph,
    Strong,
    Strikethrough,
    Link: NodeLink,
    Image: NodeLink,
    // FootnoteReference

    pub fn acceptsLines(self: NodeValue) bool {
        return switch (self) {
            .Paragraph, .Heading, .CodeBlock => true,
            else => false,
        };
    }

    pub fn canContainType(self: NodeValue, child: NodeValue) bool {
        if (child == .Document) {
            return false;
        }

        return switch (self) {
            .Document, .BlockQuote, .Item => child.block() and switch (child) {
                .Item => false,
                else => true,
            },
            .List => switch (child) {
                .Item => true,
                else => false,
            },
            .Paragraph, .Heading, .Emph, .Strong, .Link, .Image => !child.block(),
            else => false,
        };
    }

    pub fn containsInlines(self: NodeValue) bool {
        return switch (self) {
            .Paragraph, .Heading => true,
            else => false,
        };
    }

    pub fn block(self: NodeValue) bool {
        return switch (self) {
            .Document, .BlockQuote, .List, .Item, .CodeBlock, .HtmlBlock, .Paragraph, .Heading, .ThematicBreak => true,
            else => false,
        };
    }
};

pub const NodeLink = struct {
    url: []u8,
    title: []u8,
};

pub const ListType = enum {
    Bullet,
    Ordered,
};

pub const ListDelimType = enum {
    Period,
    Paren,
};

pub const NodeList = struct {
    list_type: ListType,
    marker_offset: usize,
    padding: usize,
    start: usize,
    delimiter: ListDelimType,
    bullet_char: u8,
    tight: bool,
};

pub const NodeHtmlBlock = struct {
    block_type: u8,
    literal: []u8,
};

pub const NodeCodeBlock = struct {
    fenced: bool,
    fence_char: u8,
    fence_length: usize,
    fence_offset: usize,
    info: []u8,
    literal: []u8,
};

pub const NodeHeading = struct {
    level: u32,
    setext: bool,
};
