package hide.comp.cdb;

class Cursor {

	var editor : Editor;
	public var table : Table;
	public var x : Int;
	public var y : Int;
	public var select : Null<{ x : Int, y : Int }>;
	public var onchange : Void -> Void;

	public function new(editor) {
		this.editor = editor;
		set();
	}

	public function set( ?t:Table, ?x=0, ?y=0, ?sel, update = true ) {
		if( t != null ) {
			for( t2 in editor.tables )
				if( t.sheet.name == t2.sheet.name ) {
					t = t2;
					break;
				}
		}
		this.table = t;
		this.x = x;
		this.y = y;
		this.select = sel;
		var ch = onchange;
		if( ch != null ) {
			onchange = null;
			ch();
		}
		if( update ) this.update();
	}

	public function setDefault(line, column) {
		set(editor.tables[0], column, line);
	}

	public function getLine() {
		if( table == null ) return null;
		return table.lines[y];
	}

	public function getCell() {
		var line = getLine();
		if( line == null ) return null;
		return line.cells[x];
	}

	public function save() {
		return { sheet : table.sheet, x : x, y : y, select : select == null ? null : { x : select.x, y : select.y} };
	}

	public function load( s ) {
		var table = null;
		for( t in editor.tables )
			if( t.sheet == s.sheet ) {
				table = t;
				break;
			}
		if( table == null )
			return false;
		set(table, s.x, s.y, s.select);
		return true;
	}

	public function move( dx : Int, dy : Int, shift : Bool, ctrl : Bool ) {
		if( table == null )
			table = editor.tables[0];
		if( x == -1 && ctrl ) {
			if( dy != 0 )
				editor.moveLine(getLine(), dy);
			update();
			return;
		}
		if( !shift )
			select = null;
		else if( select == null )
			select = { x : x, y : y };
		if( dx < 0 ) {
			x += dx;
			var minX = table.displayMode == Table ? -1 : 0;
			if( x < minX ) x = minX;
		}
		if( dy < 0 ) {
			y += dy;
			if( y < 0 ) y = 0;
		}
		if( dx > 0 ) {
			x += dx;
			var max = table.sheet.columns.length;
			if( x >= max ) x = max - 1;
		}
		if( dy > 0 ) {
			y += dy;
			var max = table.lines.length;
			if( y >= max ) y = max - 1;
		}
		update();
	}

	public function hide() {
		var elt = editor.element;
		elt.find(".selected").removeClass("selected");
		elt.find(".cursorView").removeClass("cursorView");
		elt.find(".cursorLine").removeClass("cursorLine");
	}

	public function update() {
		var elt = editor.element;
		hide();
		if( table == null )
			return;
		if( y < 0 ) {
			y = 0;
			select = null;
		}
		if( y >= table.lines.length ) {
			y = table.lines.length - 1;
			select = null;
		}
		var max = table.sheet.props.isProps ? 1 : table.sheet.columns.length;
		if( x >= max ) {
			x = max - 1;
			select = null;
		}
		var line = getLine();
		if( line == null )
			return;
		if( x < 0 ) {
			line.element.addClass("selected");
			if( select != null ) {
				var cy = y;
				while( select.y != cy ) {
					if( select.y > cy ) cy++ else cy--;
					table.lines[cy].element.addClass("selected");
				}
			}
		} else {
			var c = line.cells[x];
			if( c != null )
				c.element.addClass("cursorView").closest("tr").addClass("cursorLine");
			if( select != null ) {
				var s = getSelection();
				for( y in s.y1...s.y2 + 1 ) {
					var l = table.lines[y];
					for( x in s.x1...s.x2+1)
						l.cells[x].element.addClass("selected");
				}
			}
		}
		var e = line.element[0];
		if( e != null ) untyped e.scrollIntoViewIfNeeded();
	}

	public function getSelection() {
		if( table == null )
			return null;
		var x1 = if( x < 0 ) 0 else x;
		var x2 = if( x < 0 ) table.sheet.columns.length-1 else if( select != null ) select.x else x1;
		var y1 = y;
		var y2 = if( select != null ) select.y else y1;
		if( x2 < x1 ) {
			var tmp = x2;
			x2 = x1;
			x1 = tmp;
		}
		if( y2 < y1 ) {
			var tmp = y2;
			y2 = y1;
			y1 = tmp;
		}
		return { x1 : x1, x2 : x2, y1 : y1, y2 : y2 };
	}


	public function clickLine( line : Line, shiftKey = false ) {
		var sheet = line.table.sheet;
		if( shiftKey && this.table == line.table && x < 0 ) {
			select = { x : -1, y : line.index };
			update();
		} else
			set(line.table, -1, line.index);
	}

	public function clickCell( cell : Cell, shiftKey = false ) {
		var xIndex = cell.table.displayMode == Table ? cell.columnIndex : 0;
		if( shiftKey && table == cell.table ) {
			select = { x : xIndex, y : cell.line.index };
			update();
		} else
			set(cell.table, xIndex, cell.line.index);
	}

}
