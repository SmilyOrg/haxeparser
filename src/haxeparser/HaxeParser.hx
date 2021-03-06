package haxeparser;

import haxeparser.Data;
import haxe.macro.Expr;
import haxe.ds.Option;
using Lambda;

enum ParserErrorMsg {
	MissingSemicolon;
	MissingType;
	DuplicateDefault;
	Custom(s:String);
}

class ParserError {
	public var msg: ParserErrorMsg;
	public var pos: Position;
	public function new(message:ParserErrorMsg, pos:Position) {
		this.msg = message;
		this.pos = pos;
	}
}

enum SmallType {
	SNull;
	SBool(b:Bool);
	SFloat(f:Float);
	SString(s:String);
}

class HaxeCondParser extends hxparse.Parser<hxparse.LexerTokenSource<Token>, Token> implements hxparse.ParserBuilder {
	public function new(stream){
		super(stream);
	}

	public function parseMacroCond(allowOp:Bool):{tk:Option<Token>, expr:Expr}
	{
		return switch stream {
			case [{tok:Const(CIdent(t)), pos:p}]:
				parseMacroIdent(allowOp, t, p);
			case [{tok:Const(CString(s)), pos:p}]:
				{tk:None, expr:{expr:EConst(CString(s)), pos:p}};
			case [{tok:Const(CInt(s)), pos:p}]:
				{tk:None, expr:{expr:EConst(CInt(s)), pos:p}};
			case [{tok:Const(CFloat(s)), pos:p}]:
				{tk:None, expr:{expr:EConst(CFloat(s)), pos:p}};
			case [{tok:Kwd(k), pos:p}]:
				parseMacroIdent(allowOp, HaxeParser.keywordString(k), p);
			case [{tok:POpen, pos:p1}, o = parseMacroCond(true), {tok:PClose, pos:p2}]:
				var e = {expr:EParenthesis(o.expr), pos:HaxeParser.punion(p1, p2)};
				if (allowOp) parseMacroOp(e) else { tk:None, expr:e };
			case [{tok:Unop(op), pos:p}, o = parseMacroCond(allowOp)]:
				{tk:o.tk, expr:HaxeParser.makeUnop(op, o.expr, p)};
		}
	}

	function parseMacroIdent(allowOp:Bool, t:String, p:Position):{tk:Option<Token>, expr:Expr}
	{
		var e = {expr:EConst(CIdent(t)), pos:p};
		return if (!allowOp) { tk:None, expr:e } else parseMacroOp(e);
	}

	function parseMacroOp(e:Expr):{tk:Option<Token>, expr:Expr}
	{
		return switch peek(0) {
			case {tok:Binop(op)}:
				junk();
				op = switch peek(0) {
					case {tok:Binop(OpAssign)} if (op == OpGt):
						junk();
						OpGte;
					case _: op;
				}
				var o = parseMacroCond(true);
				{tk:o.tk, expr:HaxeParser.makeBinop(op, e, o.expr)};
			case tk:
				{tk:Some(tk), expr:e};
		}
	}
}

class HaxeTokenSource {
	var lexer:HaxeLexer;
	var mstack:Array<Position>;
	var defines:Map<String, Dynamic>;

	var rawSource:hxparse.LexerTokenSource<Token>;
	var condParser:HaxeCondParser;

	public function new(lexer,mstack,defines){
		this.lexer = lexer;
		this.mstack = mstack;
		this.defines = defines;

		this.rawSource = new hxparse.LexerTokenSource(lexer,HaxeLexer.tok);
		this.condParser = new HaxeCondParser(this.rawSource);
	}

	public function token():Token{
		var tk = lexer.token(HaxeLexer.tok);
		return switch tk {
			case {tok:CommentLine(_) | Comment(_) | Sharp("error" | "line")}:
				token();
			case {tok:Sharp("end")}:
				if (mstack.length == 0) tk;
				else
				{
					mstack.shift();
					token();
				}
			case {tok:Sharp("else" | "elseif")}:
				if (mstack.length == 0) tk;
				else
				{
					mstack.shift();
					skipTokens(tk.pos, false);
				}
			case {tok:Sharp("if")}:
				enterMacro(tk.pos);
			case t: t;
		}
	}

	function enterMacro(p)
	{
		var o = condParser.parseMacroCond(false);
		var tk = switch o.tk {
			case None: token();
			case Some(tk): tk;
		}
		return if (isTrue(eval(o.expr)))
		{
			mstack.unshift(p);
			tk;
		}
		else skipTokensLoop(p, true, tk);
	}

	function skipTokens(p:Position, test:Bool)
	{
		return skipTokensLoop(p, test, token());
	}

	function skipTokensLoop(p:Position, test:Bool, tk:Token)
	{
		return switch tk {
			case {tok:Sharp("end")}:
				token();
			case {tok:Sharp("elseif" | "else")} if (!test):
				skipTokens(p, test);
			case {tok:Sharp("else")}:
				mstack.unshift(tk.pos);
				token();
			case {tok:Sharp("elseif")}:
				enterMacro(tk.pos);
			case {tok:Sharp("if")}:
				skipTokensLoop(p, test, skipTokens(p, false));
			case {tok:Eof}:
				throw "unclosed macro";
			case _:
				skipTokens(p, test);
		}
	}

	function isTrue(a:SmallType)
	{
		return switch a {
			case SBool(false), SNull, SFloat(0.0), SString(""): false;
			case _: true;
		}
	}

	function compare(a:SmallType, b:SmallType)
	{
		return switch [a, b] {
			case [SNull, SNull]: 0;
			case [SFloat(a), SFloat(b)]: Reflect.compare(a, b);
			case [SString(a), SString(b)]: Reflect.compare(a, b);
			case [SBool(a), SBool(b)]: Reflect.compare(a, b);
			case [SString(a), SFloat(b)]: Reflect.compare(Std.parseFloat(a), b);
			case [SFloat(a), SString(b)]: Reflect.compare(a, Std.parseFloat(b));
			case _: 0;
		}
	}

	function eval(e:Expr)
	{
		return switch (e.expr)
		{
			case EConst(CIdent(s)): defines.exists(s) ? SString(s) : SNull;
			case EConst(CString(s)): SString(s);
			case EConst(CInt(f)), EConst(CFloat(f)): SFloat(Std.parseFloat(f));
			case EBinop(OpBoolAnd, e1, e2): SBool(isTrue(eval(e1)) && isTrue(eval(e2)));
			case EBinop(OpBoolOr, e1, e2): SBool(isTrue(eval(e1)) || isTrue(eval(e2)));
			case EUnop(OpNot, _, e): SBool(!isTrue(eval(e)));
			case EParenthesis(e): eval(e);
			case EBinop(op, e1, e2):
				var v1 = eval(e1);
				var v2 = eval(e2);
				var cmp = compare(v1, v2);
				var val = switch (op)
				{
					case OpEq: cmp == 0;
					case OpNotEq: cmp != 0;
					case OpGt: cmp > 0;
					case OpGte: cmp >= 0;
					case OpLt: cmp < 0;
					case OpLte: cmp <= 0;
					case _: throw "Unsupported operation";
				}
				SBool(val);
			case _: throw "Invalid condition expression";
		}
	}

	public function curPos():hxparse.Position{
		return lexer.curPos();
	}
}

class HaxeParser extends hxparse.Parser<HaxeTokenSource, Token> implements hxparse.ParserBuilder {

	var defines:Map<String, Dynamic>;

	var mstack:Array<Position>;
	var doResume = false;
	var doc:String;
	var inMacro:Bool;

	public function new(input:byte.ByteData, sourceName:String) {
		mstack = [];
		defines = new Map();
		defines.set("true", true);

		var lexer = new HaxeLexer(input, sourceName);
		var ts = new HaxeTokenSource(lexer, mstack, defines);
		super(ts);

		inMacro = false;
		doc = "";
	}

	public function define(flag:String, ?value:Dynamic)
	{
		defines.set(flag, value);
	}

	public function parse() {
		return parseFile();
	}

	@:allow(haxeparser.HaxeCondParser)
	static function keywordString(k:Keyword)
	{
		return Std.string(k).substr(3).toLowerCase();
	}

	@:allow(haxeparser.HaxeCondParser)
	static function punion(p1:Position, p2:Position) {
		return {
			file: p1.file,
			min: p1.min < p2.min ? p1.min : p2.min,
			max: p1.max > p2.max ? p1.max : p2.max,
		};
	}

	static function quoteIdent(s:String) {
		// TODO
		return s;
	}

	static function isLowerIdent(s:String) {
		function loop(p) {
			var c = s.charCodeAt(p);
			return if (c >= 'a'.code && c <= 'z'.code)
				true
			else if (c == '_'.code) {
				if (p + 1 < s.length)
					loop(p + 1);
				else
					true;
			} else
				false;
		}
		return loop(0);
	}

	static function isPostfix(e:Expr, u:Unop) {
		return switch (u) {
			case OpIncrement | OpDecrement:
				switch(e.expr) {
					case EConst(_) | EField(_) | EArray(_):
						true;
					case _:
						false;
				}
			case OpNot | OpNeg | OpNegBits: false;
		}
	}

	static function isPrefix(u:Unop) {
		return switch(u) {
			case OpIncrement | OpDecrement: true;
			case OpNot | OpNeg | OpNegBits: true;
		}
	}

	static function precedence(op:Binop) {
		var left = true;
		var right = false;
		return switch(op) {
			case OpMod : {p: 0, left: left};
			case OpMult | OpDiv : {p: 0, left: left};
			case OpAdd | OpSub : {p: 0, left: left};
			case OpShl | OpShr | OpUShr : {p: 0, left: left};
			case OpOr | OpAnd | OpXor : {p: 0, left: left};
			case OpEq | OpNotEq | OpGt | OpLt | OpGte | OpLte : {p: 0, left: left};
			case OpInterval : {p: 0, left: left};
			case OpBoolAnd : {p: 0, left: left};
			case OpBoolOr : {p: 0, left: left};
			case OpArrow : {p: 0, left: left};
			case OpAssign | OpAssignOp(_) : {p:10, left:right};
		}
	}

	static function isNotAssign(op:Binop) {
		return switch(op) {
			case OpAssign | OpAssignOp(_): false;
			case _: true;
		}
	}

	static function isDollarIdent(e:Expr) {
		return switch (e.expr) {
			case EConst(CIdent(n)) if (n.charCodeAt(0) == "$".code): true;
			case _: false;
		}
	}

	static function swap(op1:Binop, op2:Binop) {
		var i1 = precedence(op1);
		var i2 = precedence(op2);
		return i1.left && i1.p <= i2.p;
	}

	@:allow(haxeparser.HaxeCondParser)
	static function makeBinop(op:Binop, e:Expr, e2:Expr) {
		return switch (e2.expr) {
			case EBinop(_op,_e,_e2) if (swap(op,_op)):
				var _e = makeBinop(op,e,_e);
				{expr: EBinop(_op,_e,_e2), pos:punion(_e.pos,_e2.pos)};
			case ETernary(e1,e2,e3) if (isNotAssign(op)):
				var e = makeBinop(op,e,e1);
				{expr:ETernary(e,e2,e3), pos:punion(e.pos, e3.pos)};
			case _:
				{ expr: EBinop(op,e,e2), pos:punion(e.pos, e2.pos)};
		}
	}

	@:allow(haxeparser.HaxeCondParser)
	static function makeUnop(op:Unop, e:Expr, p1:Position) {
		return switch(e.expr) {
			case EBinop(bop,e,e2):
				{ expr: EBinop(bop, makeUnop(op,e,p1), e2), pos: punion(p1,e.pos)};
			case ETernary(e1,e2,e3):
				{ expr: ETernary(makeUnop(op,e1,p1), e2, e3), pos:punion(p1,e.pos)};
			case _:
				{ expr: EUnop(op,false,e), pos:punion(p1,e.pos)};
		}
	}

	static function makeMeta(name:String, params:Array<Expr>, e:Expr, p1:Position) {
		return switch(e.expr) {
			case EBinop(bop,e,e2):
				{ expr: EBinop(bop, makeMeta(name,params,e,p1), e2), pos: punion(p1,e.pos)};
			case ETernary(e1,e2,e3):
				{ expr: ETernary(makeMeta(name,params,e1,p1), e2, e3), pos:punion(p1,e.pos)};
			case _:
				{ expr: EMeta({name:name, params:params, pos:p1}, e), pos: punion(p1, e.pos) };
		}
	}

	static function aadd<T>(a:Array<T>, t:T) {
		a.push(t);
		return a;
	}

	function psep<T>(sep:TokenDef, f:Void->T):Array<T> {
		var acc = [];
		while(true) {
			try {
				acc.push(f());
				switch stream {
					case [{tok: sep2} && sep2 == sep]:
				}
			} catch(e:hxparse.NoMatch<Dynamic>) {
				break;
			}
		}
		return acc;
	}

	function ident() {
		return switch stream {
			case [{tok:Const(CIdent(i)),pos:p}]: { name: i, pos: p};
		}
	}

	function dollarIdent() {
		return switch stream {
			case [{tok:Const(CIdent(i)),pos:p}]: { name: i, pos: p};
			case [{tok:Dollar(i), pos:p}]: { name: "$" + i, pos: p};
		}
	}

	function dollarIdentMacro(pack:Array<String>) {
		return switch stream {
			case [{tok:Const(CIdent(i)),pos:p}]: { name: i, pos: p};
			case [{tok:Dollar(i), pos:p}]: { name: "$" + i, pos: p};
			case [{tok:Kwd(KwdMacro), pos: p} && pack.length > 0]: { name: "macro", pos: p };
		}
	}

	function lowerIdentOrMacro() {
		return switch stream {
			case [{tok:Const(CIdent(i))} && isLowerIdent(i)]: i;
			case [{tok:Kwd(KwdMacro)}]: "macro";
		}
	}

	function anyEnumIdent() {
		return switch stream {
			case [i = ident()]: i;
			case [{tok:Kwd(k), pos:p}]: {name:k.getName().toLowerCase(), pos:p};
		}
	}

	function propertyIdent() {
		return switch stream {
			case [i = ident()]: i.name;
			case [{tok:Kwd(KwdDynamic)}]: "dynamic";
			case [{tok:Kwd(KwdDefault)}]: "default";
			case [{tok:Kwd(KwdNull)}]: "null";
		}
	}

	function getDoc() {
		return "";
	}

	function comma() {
		return switch stream {
			case [{tok:Comma}]:
		}
	}

	function semicolon() {
		return if (last.tok == BrClose) {
			switch stream {
				case [{tok: Semicolon, pos:p}]: p;
				case _: last.pos;
			}
		} else switch stream {
			case [{tok: Semicolon, pos:p}]: p;
			case _:
				var pos = last.pos;
				if (doResume)
					pos
				else
					throw new ParserError(MissingSemicolon, pos);
			}
	}

	function parseFile() {
		return switch stream {
			case [{tok:Kwd(KwdPackage)}, p = parsePackage(), _ = semicolon(), l = parseTypeDecls(p,[]), {tok:Eof}]:
				{ pack: p, decls: l };
			case [l = parseTypeDecls([],[]), {tok:Eof}]:
				{ pack: [], decls: l };
		}
	}

	function parseTypeDecls(pack:Array<String>, acc:Array<TypeDecl>) {
		return switch stream {
			case [ v = parseTypeDecl(), l = parseTypeDecls(pack,aadd(acc,v)) ]:
				l;
			case _: acc;
		}
	}

	function parseTypeDecl() {
		return switch stream {
			case [{tok:Kwd(KwdImport), pos:p1}]:
				parseImport(p1);
			case [{tok:Kwd(KwdUsing), pos: p1}, t = parseTypePath(), p2 = semicolon()]:
				{decl: EUsing(t), pos: punion(p1, p2)};
			case [meta = parseMeta(), c = parseCommonFlags()]:
				switch stream {
					case [flags = parseEnumFlags(), doc = getDoc(), name = typeName(), tl = parseConstraintParams(), {tok:BrOpen}, l = parseRepeat(parseEnum), {tok:BrClose, pos: p2}]:
						{decl: EEnum({
							name: name,
							doc: doc,
							meta: meta,
							params: tl,
							flags: c.map(function(i) return i.e).concat(flags.flags),
							data: l
						}), pos: punion(flags.pos,p2)};
					case [flags = parseClassFlags(), doc = getDoc(), name = typeName(), tl = parseConstraintParams(), hl = parseRepeat(parseClassHerit), {tok:BrOpen}, fl = parseClassFields(false,flags.pos)]:
						{decl: EClass({
							name: name,
							doc: doc,
							meta: meta,
							params: tl,
							flags: c.map(function(i) return i.c).concat(flags.flags).concat(hl),
							data: fl.fields
						}), pos: punion(flags.pos,fl.pos)};
					case [{tok: Kwd(KwdTypedef), pos: p1}, doc = getDoc(), name = typeName(), tl = parseConstraintParams(), {tok:Binop(OpAssign), pos: p2}, t = parseComplexType()]:
						switch stream {
							case [{tok:Semicolon}]:
							case _:
						}
						{ decl: ETypedef({
							name: name,
							doc: doc,
							meta: meta,
							params: tl,
							flags: c.map(function(i) return i.e),
							data: t
						}), pos: punion(p1,p2)};
					case [{tok:Kwd(KwdAbstract), pos:p1}, name = typeName(), tl = parseConstraintParams(), st = parseAbstractSubtype(), sl = parseRepeat(parseAbstractRelations), {tok:BrOpen}, fl = parseClassFields(false, p1)]:
						var flags = c.map(function(flag) return switch(flag.e) { case EPrivate: APrivAbstract; case EExtern: throw 'extern abstract is not allowed'; });
						if (st != null) {
							flags.push(AIsType(st));
						}
						{ decl: EAbstract({
							name: name,
							doc: doc,
							meta: meta,
							params: tl,
							flags: flags.concat(sl),
							data: fl.fields
						}), pos: punion(p1, fl.pos)};
				}
		}
	}

	function parseClass(meta:Metadata, cflags:Array<{fst: ClassFlag, snd:String}>, needName:Bool) {
		var optName = if (needName) typeName else function() {
			var t = parseOptional(typeName);
			return t == null ? "" : t;
		}
		return switch stream {
			case [flags = parseClassFlags(), doc = getDoc(), name = optName(), tl = parseConstraintParams(), hl = psep(Comma,parseClassHerit), {tok: BrOpen}, fl = parseClassFields(false,flags.pos)]:
				{ decl: EClass({
					name: name,
					doc: doc,
					meta: meta,
					params: tl,
					flags: cflags.map(function(i) return i.fst).concat(flags.flags).concat(hl),
					data: fl.fields
				}), pos: punion(flags.pos,fl.pos)};
		}
	}

	function parseImport(p1:Position) {
		var acc = switch stream {
			case [{tok:Const(CIdent(name)), pos:p}]: [{pack:name, pos:p}];
			case _: unexpected();
		}
		while(true) {
			switch stream {
				case [{tok: Dot}]:
					switch stream {
						case [{tok:Const(CIdent(k)), pos: p}]:
							acc.push({pack:k,pos:p});
						case [{tok:Kwd(KwdMacro), pos:p}]:
							acc.push({pack:"macro",pos:p});
						case [{tok:Binop(OpMult)}, {tok:Semicolon, pos:p2}]:
							return {
								decl: EImport(acc, IAll),
								pos: p2
							}
						case _: unexpected();
					}
				case [{tok:Semicolon, pos:p2}]:
					return {
						decl: EImport(acc, INormal),
						pos: p2
					}
				case [{tok:Kwd(KwdIn)}, {tok:Const(CIdent(name))}, {tok:Semicolon, pos:p2}]:
					return {
						decl: EImport(acc, IAsName(name)),
						pos: p2
					}
				case _: unexpected();
			}
		}
	}

	function parseAbstractRelations() {
		return switch stream {
			case [{tok:Const(CIdent("to"))}, t = parseComplexType()]: AToType(t);
			case [{tok:Const(CIdent("from"))}, t = parseComplexType()]: AFromType(t);
		}
	}

	function parseAbstractSubtype() {
		return switch stream {
			case [{tok:POpen}, t = parseComplexType(), {tok:PClose}]: t;
			case _: null;
		}
	}

	function parsePackage() {
		return psep(Dot, lowerIdentOrMacro);
	}

	function parseClassFields(tdecl:Bool, p1:Position):{fields:Array<Field>, pos:Position} {
		var l = parseClassFieldResume(tdecl);
		var p2 = switch stream {
			case [{tok: BrClose, pos: p2}]:
				p2;
			case _: unexpected();
		}
		return {
			fields: l,
			pos: p2
		}
	}

	function parseClassFieldResume(tdecl:Bool):Array<Field> {
		return parseRepeat(parseClassField);
	}

	function parseCommonFlags():Array<{c:ClassFlag, e:EnumFlag}> {
		return switch stream {
			case [{tok:Kwd(KwdPrivate)}, l = parseCommonFlags()]: aadd(l, {c:HPrivate, e:EPrivate});
			case [{tok:Kwd(KwdExtern)}, l = parseCommonFlags()]: aadd(l, {c:HExtern, e:EExtern});
			case _: [];
		}
	}

	function parseMetaParams(pname:Position) {
		return switch stream {
			case [{tok: POpen, pos:p} && p.min == pname.max, params = psep(Comma, expr), {tok: PClose}]: params;
			case _: [];
		}
	}

	function parseMetaEntry() {
		return switch stream {
			case [{tok:At}, name = metaName(), params = parseMetaParams(name.pos)]: {name: name.name, params: params, pos: name.pos};
		}
	}

	function parseMeta() {
		return switch stream {
			case [entry = parseMetaEntry()]: aadd(parseMeta(), entry);
			case _: [];
		}
	}

	function metaName() {
		return switch stream {
			case [{tok:Const(CIdent(i)), pos:p}]: {name: i, pos: p};
			case [{tok:Kwd(k), pos:p}]: {name: k.getName().toLowerCase(), pos:p};
			case [{tok:DblDot}]:
				switch stream {
					case [{tok:Const(CIdent(i)), pos:p}]: {name: ':$i', pos: p};
					case [{tok:Kwd(k), pos:p}]: {name: ":" +k.getName().toLowerCase(), pos:p};
				}
		}
	}

	function parseEnumFlags() {
		return switch stream {
			case [{tok:Kwd(KwdEnum), pos:p}]: {flags: [], pos: p};
		}
	}

	function parseClassFlags() {
		return switch stream {
			case [{tok:Kwd(KwdClass), pos:p}]: {flags: [], pos: p};
			case [{tok:Kwd(KwdInterface), pos:p}]: {flags: aadd([],HInterface), pos: p};
		}
	}

	function parseTypeOpt() {
		return switch stream {
			case [{tok:DblDot}, t = parseComplexType()]: t;
			case _: null;
		}
	}

	function parseComplexType() {
		var t = parseComplexTypeInner();
		return parseComplexTypeNext(t);
	}

	function parseComplexTypeInner():ComplexType {
		return switch stream {
			case [{tok:POpen}, t = parseComplexType(), {tok:PClose}]: TParent(t);
			case [{tok:BrOpen, pos: p1}]:
				switch stream {
					case [l = parseTypeAnonymous(false)]: TAnonymous(l);
					case [{tok:Binop(OpGt)}, t = parseTypePath(), {tok:Comma}]:
						switch stream {
							case [l = parseTypeAnonymous(false)]: TExtend([t],l);
							case [fl = parseClassFields(true, p1)]: TExtend([t], fl.fields);
							case _: unexpected();
						}
					case [l = parseClassFields(true, p1)]: TAnonymous(l.fields);
					case _: unexpected();
				}
			case [{tok:Question}, t = parseComplexTypeInner()]:
				TOptional(t);
			case [t = parseTypePath()]:
				TPath(t);
		}
	}

	function parseTypePath() {
		return parseTypePath1([]);
	}

	function parseTypePath1(pack:Array<String>) {
		return switch stream {
			case [ident = dollarIdentMacro(pack)]:
				if (isLowerIdent(ident.name)) {
					switch stream {
						case [{tok:Dot}]:
							parseTypePath1(aadd(pack, ident.name));
						case [{tok:Semicolon}]:
							throw new ParserError(Custom("Type name should start with an uppercase letter"), ident.pos);
						case _: unexpected();
					}
				} else {
					var sub = switch stream {
						case [{tok:Dot}]:
							switch stream {
								case [{tok:Const(CIdent(name))} && !isLowerIdent(name)]: name;
								case _: unexpected();
							}
						case _:
							null;
					}
					var params = switch stream {
						case [{tok:Binop(OpLt)}, l = psep(Comma, parseTypePathOrConst), {tok:Binop(OpGt)}]: l;
						case _: [];
					}
					{
						pack: pack,
						name: ident.name,
						params: params,
						sub: sub
					}
				}
		}
	}

	function typeName() {
		return switch stream {
			case [{tok: Const(CIdent(name)), pos:p}]:
				if (isLowerIdent(name)) throw new ParserError(Custom("Type name should start with an uppercase letter"), p);
				else name;
		}
	}

	function parseTypePathOrConst() {
		return switch stream {
			case [{tok:BkOpen, pos: p1}, l = parseArrayDecl(), {tok:BkClose, pos:p2}]: TPExpr({expr: EArrayDecl(l), pos:punion(p1,p2)});
			case [t = parseComplexType()]: TPType(t);
			case [{tok:Const(c), pos:p}]: TPExpr({expr:EConst(c), pos:p});
			case [e = expr()]: TPExpr(e);
			case _: unexpected();
		}
	}

	function parseComplexTypeNext(t:ComplexType) {
		return switch stream {
			case [{tok:Arrow}, t2 = parseComplexType()]:
				switch(t2) {
					case TFunction(args,r):
						TFunction(aadd(args,t),r);
					case _:
						TFunction([t],t2);
				}
			case _: t;
		}
	}

	function parseTypeAnonymous(opt:Bool):Array<Field> {
		return switch stream {
			case [id = ident(), {tok:DblDot}, t = parseComplexType()]:
				function next(p2,acc) {
					var t = !opt ? t : switch(t) {
						case TPath({pack:[], name:"Null"}): t;
						case _: TPath({pack:[], name:"Null", sub:null, params:[TPType(t)]});
					}
					return aadd(acc, {
						name: id.name,
						meta: opt ? [{name:":optional",params:[], pos:id.pos}] : [],
						access: [],
						doc: null,
						kind: FVar(t,null),
						pos: punion(id.pos, p2)
					});
				}
				switch stream {
					case [{tok:BrClose, pos:p2}]: next(p2, []);
					case [{tok:Comma, pos:p2}]:
						switch stream {
							case [{tok:BrClose}]: next(p2, []);
							case [l = parseTypeAnonymous(false)]: next(p2, l);
							case _: unexpected();
						}
					case _: unexpected();
				}
			case [{tok:Question} && !opt]: parseTypeAnonymous(true);
		}
	}

	function parseEnum() {
		doc = null;
		var meta = parseMeta();
		return switch stream {
			case [name = anyEnumIdent(), doc = getDoc(), params = parseConstraintParams()]:
				var args = switch stream {
					case [{tok:POpen}, l = psep(Comma, parseEnumParam), {tok:PClose}]: l;
					case _: [];
				}
				var t = switch stream {
					case [{tok:DblDot}, t = parseComplexType()]: t;
					case _: null;
				}
				var p2 = switch stream {
					case [p = semicolon()]: p;
					case _: unexpected();
				}
				{
					name: name.name,
					doc: doc,
					meta: meta,
					args: args,
					params: params,
					type: t,
					pos: punion(name.pos, p2)
				}
		}
	}

	function parseEnumParam() {
		return switch stream {
			case [{tok:Question}, name = ident(), {tok:DblDot}, t = parseComplexType()]: { name: name.name, opt: true, type: t};
			case [name = ident(), {tok:DblDot}, t = parseComplexType()]: { name: name.name, opt: false, type: t };
		}
	}

	function parseClassField():Field {
		doc = null;
		return switch stream {
			case [meta = parseMeta(), al = parseCfRights(true,[]), doc = getDoc()]:
				var data = switch stream {
					case [{tok:Kwd(KwdVar), pos:p1}, name = ident()]:
						switch stream {
							case [{tok:POpen}, i1 = propertyIdent(), {tok:Comma}, i2 = propertyIdent(), {tok:PClose}]:
								var t = switch stream {
									case [{tok:DblDot}, t = parseComplexType()]: t;
									case _: null;
								}
								var e = switch stream {
									case [{tok:Binop(OpAssign)}, e = toplevelExpr(), p2 = semicolon()]: { expr: e, pos: p2 };
									case [{tok:Semicolon, pos:p2}]: { expr: null, pos: p2 };
									case _: unexpected();
								}
								{
									name: name.name,
									pos: punion(p1,e.pos),
									kind: FProp(i1,i2,t,e.expr)
								}
							case [t = parseTypeOpt()]:
								var e = switch stream {
									case [{tok:Binop(OpAssign)}, e = toplevelExpr(), p2 = semicolon()]: { expr: e, pos: p2 };
									case [{tok:Semicolon, pos:p2}]: { expr: null, pos: p2 };
									case _: unexpected();
								}
								{
									name: name.name,
									pos: punion(p1,e.pos),
									kind: FVar(t,e.expr)
								}
						}
					case [{tok:Kwd(KwdFunction), pos:p1}, name = parseFunName(), pl = parseConstraintParams(), {tok:POpen}, al = psep(Comma, parseFunParam), {tok:PClose}, t = parseTypeOpt()]:
						var e = switch stream {
							case [e = toplevelExpr(), _ = semicolon()]:
								{ expr: e, pos: e.pos };
							case [{tok: Semicolon,pos:p}]:
								{ expr: null, pos: p}
							case _: unexpected();
						}
						var f = {
							params: pl,
							args: al,
							ret: t,
							expr: e.expr
						}
						{
							name: name,
							pos: punion(p1, e.pos),
							kind: FFun(f)
						}
					case _:
						if (al.length == 0)
							throw noMatch();
						else
							unexpected();
				}
			{
				name: data.name,
				doc: doc,
				meta: meta,
				access: al,
				pos: data.pos,
				kind: data.kind
			}
		}
	}

	function parseCfRights(allowStatic:Bool, l:Array<Access>) {
		return switch stream {
			case [{tok:Kwd(KwdStatic)} && allowStatic, l = parseCfRights(false, aadd(l, AStatic))]: l;
			case [{tok:Kwd(KwdMacro)} && !l.has(AMacro), l = parseCfRights(allowStatic, aadd(l, AMacro))]: l;
			case [{tok:Kwd(KwdPublic)} && !(l.has(APublic) || l.has(APrivate)), l = parseCfRights(allowStatic, aadd(l, APublic))]: l;
			case [{tok:Kwd(KwdPrivate)} && !(l.has(APublic) || l.has(APrivate)), l = parseCfRights(allowStatic, aadd(l, APrivate))]: l;
			case [{tok:Kwd(KwdOverride)} && !l.has(AOverride), l = parseCfRights(false, aadd(l, AOverride))]: l;
			case [{tok:Kwd(KwdDynamic)} && !l.has(ADynamic), l = parseCfRights(allowStatic, aadd(l, ADynamic))]: l;
			case [{tok:Kwd(KwdInline)}, l = parseCfRights(allowStatic, aadd(l, AInline))]: l;
			case _: l;
		}
	}

	function parseFunName() {
		return switch stream {
			case [{tok:Const(CIdent(name))}]: name;
			case [{tok:Kwd(KwdNew)}]: "new";
		}
	}

	function parseFunParam() {
		return switch stream {
			case [{tok:Question}, id = ident(), t = parseTypeOpt(), c = parseFunParamValue()]: { name: id.name, opt: true, type: t, value: c};
			case [id = ident(), t = parseTypeOpt(), c = parseFunParamValue()]: { name: id.name, opt: false, type: t, value: c};

		}
	}

	function parseFunParamValue() {
		return switch stream {
			case [{tok:Binop(OpAssign)}, e = toplevelExpr()]: e;
			case _: null;
		}
	}

	function parseFunParamType() {
		return switch stream {
			case [{tok:Question}, id = ident(), {tok:DblDot}, t = parseComplexType()]: { name: id.name, opt: true, type: t};
			case [ id = ident(), {tok:DblDot}, t = parseComplexType()]: { name: id.name, opt: false, type: t};
		}
	}

	function parseConstraintParams() {
		return switch stream {
			case [{tok:Binop(OpLt)}, l = psep(Comma, parseConstraintParam), {tok:Binop((OpGt))}]: l;
			case _: [];
		}
	}

	function parseConstraintParam() {
		return switch stream {
			case [name = typeName()]:
				var params = [];
				var ctl = switch stream {
					case [{tok:DblDot}]:
						switch stream {
							case [{tok:POpen}, l = psep(Comma, parseComplexType), {tok:PClose}]: l;
							case [t = parseComplexType()]: [t];
							case _: unexpected();
						}
					case _: [];
				}
				{
					name: name,
					params: params,
					constraints: ctl
				}
		}
	}

	function parseClassHerit() {
		return switch stream {
			case [{tok:Kwd(KwdExtends)}, t = parseTypePath()]: HExtends(t);
			case [{tok:Kwd(KwdImplements)}, t = parseTypePath()]: HImplements(t);
		}
	}

	function block1() {
		return switch stream {
			case [{tok:Const(CIdent(name)), pos:p}]: block2(name, CIdent(name), p);
			case [{tok:Const(CString(name)), pos:p}]: block2(quoteIdent(name), CString(name), p);
			case [b = block([])]: EBlock(b);
		}
	}

	function block2(name:String, ident:Constant, p:Position) {
		return switch stream {
			case [{tok:DblDot}, e = expr(), l = parseObjDecl()]:
				l.unshift({field:name, expr:e});
				EObjectDecl(l);
			case _:
				var e = exprNext({expr:EConst(ident), pos: p});
				var _ = semicolon();
				var b = block([e]);
				EBlock(b);
		}
	}

	function block(acc:Array<Expr>) {
		try {
			var e = parseBlockElt();
			return block(aadd(acc,e));
		} catch(e:hxparse.NoMatch<Dynamic>) {
			return acc;
		}
	}

	function parseBlockElt() {
		return switch stream {
			case [{tok:Kwd(KwdVar), pos:p1}, vl = psep(Comma, parseVarDecl), p2 = semicolon()]: { expr: EVars(vl), pos:punion(p1,p2)};
			case [e = expr(), _ = semicolon()]: e;
		}
	}

	function parseObjDecl() {
		var acc = [];
		while(true) {
			switch stream {
				case [{tok:Comma}]:
					switch stream {
						case [id = ident(), {tok:DblDot}, e = expr()]:
							acc.push({field:id.name, expr: e});
						case [{tok:Const(CString(name))}, {tok:DblDot}, e = expr()]:
							//aadd(l,{field:quoteIdent(name), expr: e});
							acc.push({field:quoteIdent(name), expr: e});
						case _:
							break;
					}
				case _:
					break;
			}
		}
		return acc;
	}

	function parseArrayDecl() {
		var acc = [];
		var br = false;
		while(true) {
			switch stream {
				case [e = expr()]:
					acc.push(e);
					switch stream {
						case [{tok: Comma}]:
						case _: br = true;
					}
				case _: br = true;
			}
			if (br) break;
		}
		return acc;
	}

	function parseVarDecl() {
		return switch stream {
			case [id = dollarIdent(), t = parseTypeOpt()]:
				switch stream {
					case [{tok:Binop(OpAssign)}, e = expr()]: { name: id.name, type: t, expr: e};
					case _: { name: id.name, type:t, expr: null};
				}
		}
	}

	function inlineFunction() {
		return switch stream {
			case [{tok:Kwd(KwdInline)}, {tok:Kwd(KwdFunction), pos:p1}]: { isInline: true, pos: p1};
			case [{tok:Kwd(KwdFunction), pos: p1}]: { isInline: false, pos: p1};
		}
	}

	function reify(inMacro:Bool) {
		// TODO
		return {
			toExpr: function(e) return null,
			toType: function(t,p) return null,
			toTypeDef: function(t) return null,
		}
	}

	function reifyExpr(e:Expr) {
		var toExpr = reify(inMacro).toExpr;
		var e = toExpr(e);
		return { expr: ECheckType(e, TPath( {pack:["haxe","macro"], name:"Expr", sub:null, params: []})), pos: e.pos};
	}

	function parseMacroExpr(p:Position) {
		return switch stream {
			case [{tok:DblDot}, t = parseComplexType()]:
				var toType = reify(inMacro).toType;
				var t = toType(t,p);
				{ expr: ECheckType(t, TPath( {pack:["haxe","macro"], name:"Expr", sub:"ComplexType", params: []})), pos: p};
			case [{tok:Kwd(KwdVar), pos:p1}, vl = psep(Comma, parseVarDecl)]:
				reifyExpr({expr:EVars(vl), pos:p1});
			case [{tok:BkOpen}, d = parseClass([],[],false)]:
				var toType = reify(inMacro).toTypeDef;
				{ expr: ECheckType(toType(d), TPath( {pack:["haxe","macro"], name:"Expr", sub:"TypeDefinition", params: []})), pos: p};
			case [e = secureExpr()]:
				reifyExpr(e);
		}
	}

	public function expr():Expr {
		return switch stream {
			case [meta = parseMetaEntry()]:
				makeMeta(meta.name, meta.params, secureExpr(), meta.pos);
			case [{tok:BrOpen, pos:p1}, b = block1(), {tok:BrClose, pos:p2}]:
				var e = { expr: b, pos: punion(p1, p2)};
				switch(b) {
					case EObjectDecl(_): exprNext(e);
					case _: e;
				}
			case [{tok:Kwd(KwdMacro), pos:p}]:
				parseMacroExpr(p);
			case [{tok:Kwd(KwdVar), pos: p1}, v = parseVarDecl()]: { expr: EVars([v]), pos: p1};
			case [{tok:Const(c), pos:p}]: exprNext({expr:EConst(c), pos:p});
			case [{tok:Kwd(KwdThis), pos:p}]: exprNext({expr: EConst(CIdent("this")), pos:p});
			case [{tok:Kwd(KwdTrue), pos:p}]: exprNext({expr: EConst(CIdent("true")), pos:p});
			case [{tok:Kwd(KwdFalse), pos:p}]: exprNext({expr: EConst(CIdent("false")), pos:p});
			case [{tok:Kwd(KwdNull), pos:p}]: exprNext({expr: EConst(CIdent("null")), pos:p});
			case [{tok:Kwd(KwdCast), pos:p1}]:
				switch stream {
					case [{tok:POpen}, e = expr()]:
						switch stream {
							case [{tok:Comma}, t = parseComplexType(), {tok:PClose, pos:p2}]: exprNext({expr:ECast(e,t), pos: punion(p1,p2)});
							case [{tok:PClose, pos:p2}]: exprNext({expr:ECast(e,null),pos:punion(p1,p2)});
							case _: unexpected();
						}
					case [e = secureExpr()]: exprNext({expr:ECast(e,null), pos:punion(p1, e.pos)});
				}
			case [{tok:Kwd(KwdThrow), pos:p}, e = expr()]: { expr: EThrow(e), pos: p};
			case [{tok:Kwd(KwdNew), pos:p1}, t = parseTypePath(), {tok:POpen, pos:_}]:
				switch stream {
					case [al = psep(Comma, expr), {tok:PClose, pos:p2}]: exprNext({expr:ENew(t,al), pos:punion(p1, p2)});
					case _: unexpected();
				}
			case [{tok:POpen, pos: p1}, e = expr(), {tok:PClose, pos:p2}]: exprNext({expr:EParenthesis(e), pos:punion(p1, p2)});
			case [{tok:BkOpen, pos:p1}, l = parseArrayDecl(), {tok:BkClose, pos:p2}]: exprNext({expr: EArrayDecl(l), pos:punion(p1,p2)});
			case [inl = inlineFunction(), name = parseOptional(dollarIdent), pl = parseConstraintParams(), {tok:POpen}, al = psep(Comma,parseFunParam), {tok:PClose}, t = parseTypeOpt()]:
				function make(e) {
					var f = {
						params: pl,
						ret: t,
						args: al,
						expr: e
					};
					return { expr: EFunction(name == null ? null : inl.isInline ? "inline_" + name.name : name.name, f), pos: punion(inl.pos, e.pos)};
				}
				exprNext(make(secureExpr()));
			case [{tok:Unop(op), pos:p1}, e = expr()]: makeUnop(op,e,p1);
			case [{tok:Binop(OpSub), pos:p1}, e = expr()]:
				function neg(s:String) {
					return s.charCodeAt(0) == '-'.code
						? s.substr(1)
						: "-" + s;
				}
				switch (makeUnop(OpNeg,e,p1)) {
					case {expr:EUnop(OpNeg,false,{expr:EConst(CInt(i))}), pos:p}:
						{expr:EConst(CInt(neg(i))), pos:p};
					case {expr:EUnop(OpNeg,false,{expr:EConst(CFloat(j))}), pos:p}:
						{expr:EConst(CFloat(neg(j))), pos:p};
					case e: e;
				}
			case [{tok:Kwd(KwdFor), pos:p}, {tok:POpen}, it = expr(), {tok:PClose}]:
				var e = secureExpr();
				{ expr: EFor(it,e), pos:punion(p, e.pos)};
			case [{tok:Kwd(KwdIf), pos:p}, {tok:POpen}, cond = expr(), {tok:PClose}, e1 = expr()]:
				var e2 = switch stream {
					case [{tok:Kwd(KwdElse)}, e2 = expr()]: e2;
					case _:
						switch [peek(0),peek(1)] {
							case [{tok:Semicolon}, {tok:Kwd(KwdElse)}]:
								junk();
								junk();
								secureExpr();
							case _: null;
						}
				}
				{ expr: EIf(cond,e1,e2), pos:punion(p, e2 == null ? e1.pos : e2.pos)};
			case [{tok:Kwd(KwdReturn), pos:p}, e = parseOptional(expr)]: { expr: EReturn(e), pos: e == null ? p : punion(p,e.pos)};
			case [{tok:Kwd(KwdBreak), pos:p}]: { expr: EBreak, pos: p };
			case [{tok:Kwd(KwdContinue), pos:p}]: { expr: EContinue, pos: p};
			case [{tok:Kwd(KwdWhile), pos:p1}, {tok:POpen}, cond = expr(), {tok:PClose}]:
				var e = secureExpr();
				{ expr: EWhile(cond, e, true), pos: punion(p1, e.pos)};
			case [{tok:Kwd(KwdDo), pos:p1}, e = expr(), {tok:Kwd(KwdWhile)}, {tok:POpen}, cond = expr(), {tok:PClose}]: { expr: EWhile(cond,e,false), pos:punion(p1, e.pos)};
			case [{tok:Kwd(KwdSwitch), pos:p1}, e = expr(), {tok:BrOpen}, cases = parseSwitchCases(), {tok:BrClose, pos:p2}]:
				{ expr: ESwitch(e,cases.cases,cases.def), pos:punion(p1,p2)};
			case [{tok:Kwd(KwdTry), pos:p1}, e = expr(), cl = parseRepeat(parseCatch)]:
				{ expr: ETry(e,cl), pos:p1};
			case [{tok:IntInterval(i), pos:p1}, e2 = expr()]: makeBinop(OpInterval,{expr:EConst(CInt(i)), pos:p1}, e2);
			case [{tok:Kwd(KwdUntyped), pos:p1}, e = expr()]: { expr: EUntyped(e), pos:punion(p1,e.pos)};
			case [{tok:Dollar(v), pos:p}]: exprNext({expr:EConst(CIdent("$" + v)), pos:p});
		}
	}

	function toplevelExpr():Expr {
		return expr();
	}

	function exprNext(e1:Expr):Expr {
		return switch stream {
			case [{tok:Dot, pos:p}]:
				switch stream {
					case [{tok:Dollar(v), pos:p2}]:
						exprNext({expr:EField(e1, "$" + v), pos:punion(e1.pos, p2)});
					case [{tok:Const(CIdent(f)), pos:p2} && p.max == p2.min]:
						exprNext({expr:EField(e1,f), pos:punion(e1.pos,p2)});
					case [{tok:Kwd(KwdMacro), pos:p2} && p.max == p2.min]:
						exprNext({expr:EField(e1,"macro"), pos:punion(e1.pos,p2)});
					case _:
						switch(e1) {
							case {expr: EConst(CInt(v)), pos:p2} if (p2.max == p.min):
								exprNext({expr:EConst(CFloat(v + ".")), pos:punion(p,p2)});
							case _: unexpected();
						}
				}
			case [{tok:POpen, pos:_}]:
				switch stream {
					case [params = parseCallParams(), {tok:PClose, pos:p2}]:
						exprNext({expr:ECall(e1,params),pos:punion(e1.pos,p2)});
					case _: unexpected();
				}
			case [{tok:BkOpen}, e2 = expr(), {tok:BkClose, pos:p2}]:
				exprNext({expr:EArray(e1,e2), pos:punion(e1.pos,p2)});
			case [{tok:Binop(OpGt)}]:
				switch stream {
					case [{tok:Binop(OpGt)}]:
						switch stream {
							case [{tok:Binop(OpGt)}]:
								switch stream {
									case [{tok:Binop(OpAssign)}, e2 = expr()]:
										makeBinop(OpAssignOp(OpUShr),e1,e2);
									case [e2 = secureExpr()]: makeBinop(OpUShr,e1,e2);
								}
							case [{tok:Binop(OpAssign)}, e2 = expr()]:
								makeBinop(OpAssignOp(OpShr),e1,e2);
							case [e2 = secureExpr()]:
								makeBinop(OpShr,e1,e2);
						}
					case [{tok:Binop(OpAssign)}]:
						makeBinop(OpGte,e1,secureExpr());
					case [e2 = secureExpr()]:
						makeBinop(OpGt,e1,e2);
				}
			case [{tok:Binop(op)}, e2 = expr()]:
				makeBinop(op,e1,e2);
			case [{tok:Question}, e2 = expr(), {tok:DblDot}, e3 = expr()]:
				{ expr: ETernary(e1,e2,e3), pos: punion(e1.pos, e3.pos)};
			case [{tok:Kwd(KwdIn)}, e2 = expr()]:
				{expr:EIn(e1,e2), pos:punion(e1.pos, e2.pos)};
			case [{tok:Unop(op), pos:p} && isPostfix(e1,op)]:
				exprNext({expr:EUnop(op,true,e1), pos:punion(e1.pos, p)});
			case [{tok:BrOpen, pos:p1} && isDollarIdent(e1), eparam = expr(), {tok:BrClose,pos:p2}]:
				switch (e1.expr) {
					case EConst(CIdent(n)):
						exprNext({expr: EMeta({name:n, params:[], pos:e1.pos},eparam), pos:punion(p1,p2)});
					case _: throw false;
				}
			case _: e1;
		}
	}

	function parseGuard() {
		return switch stream {
			case [{tok:Kwd(KwdIf)}, {tok:POpen}, e = expr(), {tok:PClose}]:
				e;
		}
	}

	function parseSwitchCases() {
		var cases = [];
		var def = null;
		function caseBlock(b:Array<Expr>, p:Position) {
			return if (b.length == 0) {
				null;
			} else switch(b) {
				case [e = macro $b{el}]: e;
				case _: { expr: EBlock(b), pos: p};
			}
		}
		while(true) {
			switch stream {
				case [{tok:Kwd(KwdDefault), pos:p1}, {tok:DblDot}]:
					var b = block([]);
					var e = caseBlock(b, p1);
					if (e == null) {
						e = { expr: null, pos: p1 };
					}
					if (def != null) {
						throw new ParserError(DuplicateDefault, p1);
					}
					def = e;
				case [{tok:Kwd(KwdCase), pos:p1}, el = psep(Comma,expr), eg = parseOptional(parseGuard), {tok:DblDot}]:
					var b = block([]);
					var e = caseBlock(b, p1);
					cases.push({values:el,guard:eg,expr:e});
				case _:
					break;
			}
		}
		return {
			cases: cases,
			def: def
		}
	}

	function parseCatch() {
		return switch stream {
			case [{tok:Kwd(KwdCatch), pos:p}, {tok:POpen}, id = ident(), ]:
				switch stream {
					case [{tok:DblDot}, t = parseComplexType(), {tok:PClose}]:
						{
							name: id.name,
							type: t,
							expr: secureExpr()
						}
					case _:
						throw new ParserError(MissingType, p);
				}
		}
	}

	function parseCallParams() {
		var ret = [];
		switch stream {
			case [e = expr()]: ret.push(e);
			case _: return [];
		}
		while(true) {
			switch stream {
				case [{tok: Comma}, e = expr()]: ret.push(e);
				case _: break;
			}
		}
		return ret;
	}

	function secureExpr() {
		return expr();
	}
}