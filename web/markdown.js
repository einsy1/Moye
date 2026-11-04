import {Marked} from 'marked';

// Extend tokens rather than rewriting source: code, links and HTML stay intact.
const parser = new Marked({gfm:true, breaks:true});
parser.use({
  extensions:[{
    name:'naturalQuote', level:'block',
    start(src) { return /^ {0,3}>/m.exec(src)?.index; },
    tokenizer(src) {
      const match = /^(?: {0,3}>[^\n]*(?:\n|$))+/.exec(src);
      if (!match) return;
      const text = match[0].replace(/^ {0,3}> ?/gm,'');
      return {type:'naturalQuote', raw:match[0], tokens:this.lexer.blockTokens(text)};
    },
    renderer(token) { return '<blockquote>\n'+this.parser.parse(token.tokens)+'</blockquote>\n'; }
  },{
    name:'looseHeading', level:'block',
    start(src) { return /^ {0,3}#{1,6}[^#\s]/m.exec(src)?.index; },
    tokenizer(src) {
      const match = /^ {0,3}(#{1,6})([^#\s][^\n]*)(?:\n|$)/.exec(src);
      if (!match) return;
      const text = match[2].replace(/\s+#+\s*$/, '').trim();
      return {type:'looseHeading', raw:match[0], depth:match[1].length, tokens:this.lexer.inlineTokens(text)};
    },
    renderer(token) { return `<h${token.depth}>${this.parser.parseInline(token.tokens)}</h${token.depth}>\n`; }
  },{
    name:'highlight', level:'inline',
    start(src) { return src.indexOf('=='); },
    tokenizer(src) {
      const match = /^==([^=\n]+)==/.exec(src);
      if (match) return {type:'highlight', raw:match[0], tokens:this.lexer.inlineTokens(match[1])};
    },
    renderer(token) { return '<mark>'+this.parser.parseInline(token.tokens)+'</mark>'; }
  }]
});
export const renderMarkdown = text => parser.parse(text);
