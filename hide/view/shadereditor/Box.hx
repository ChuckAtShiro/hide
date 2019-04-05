package hide.view.shadereditor;

import hide.comp.SVG;
import js.jquery.JQuery;
import hrt.shgraph.ShaderNode;

class Box {

	var nodeInstance : ShaderNode;

	var x : Float;
	var y : Float;

	var width : Int = 150;
	var height : Int;
	var paramHeight : Int = 0;

	var HEADER_HEIGHT = 27;
	@const var NODE_MARGIN = 20;
	public static var NODE_RADIUS = 5;
	@const var NODE_TITLE_PADDING = 10;
	public var selected : Bool = false;

	public var inputs : Array<JQuery> = [];
	public var outputs : Array<JQuery> = [];

	var element : JQuery;
	var parametersGroup : JQuery;

	public function new(editor : SVG, parent : JQuery, x : Float, y : Float, node : ShaderNode) {
		this.nodeInstance = node;

		var metas = haxe.rtti.Meta.getType(Type.getClass(node));
		if (metas.width != null) {
			this.width = metas.width[0];
		}
		var className = (metas.name != null) ? metas.name[0] : "Undefined";

		element = editor.group(parent).addClass("not-selected");
		setPosition(x, y);

		// outline of box
		editor.rect(element, -1, -1, width+2, getHeight()+2).addClass("outline");

		// header

		if (Reflect.hasField(metas, "noheader")) {
			HEADER_HEIGHT = 0;
		} else {
			editor.rect(element, 0, 0, this.width, HEADER_HEIGHT).addClass("head-box");
			editor.text(element, 10, HEADER_HEIGHT-8, className).addClass("title-box");
		}

		parametersGroup = editor.group(element).addClass("parameters-group");

		// nodes div
		editor.rect(element, 0, HEADER_HEIGHT, this.width, 0).addClass("nodes");
		editor.line(element, width/2, HEADER_HEIGHT, width/2, 0, {display: "none"}).addClass("nodes-separator");
	}

	public function addInput(editor : SVG, name : String) {
		var node = editor.group(element).addClass("input-node-group");
		var nodeHeight = HEADER_HEIGHT + (NODE_MARGIN + NODE_RADIUS) * (inputs.length+1);
		var nodeCircle = editor.circle(node, 0, nodeHeight, NODE_RADIUS).addClass("node input-node");

		if (name.length > 0)
			editor.text(node, NODE_TITLE_PADDING, nodeHeight + 4, name).addClass("title-node");

		inputs.push(nodeCircle);
		refreshHeight();

		return node;
	}

	public function addOutput(editor : SVG, name : String) {
		var node = editor.group(element).addClass("output-node-group");
		var nodeHeight = HEADER_HEIGHT + (NODE_MARGIN + NODE_RADIUS) * (outputs.length+1);
		var nodeCircle = editor.circle(node, width, nodeHeight, NODE_RADIUS).addClass("node output-node");

		if (name.length > 0)
			editor.text(node, width - NODE_TITLE_PADDING - (name.length * 6.75), nodeHeight + 4, name).addClass("title-node");

		outputs.push(nodeCircle);

		refreshHeight();
		return node;
	}

	public function generateParameters(editor : SVG) {
		var params = nodeInstance.getParametersHTML(this.width);

		if (params.length == 0) return;

		if (inputs.length <= 1 && outputs.length <= 1) {
			element.find(".nodes").remove();
			element.find(".input-node-group > .title-node").html("");
			element.find(".output-node-group > .title-node").html("");
		}

			// create param box
		editor.rect(parametersGroup, 0, 0, this.width, 0).addClass("parameters");
		paramHeight = 10;

		for (p in params) {
			var param = editor.group(parametersGroup).addClass("param-group");
			param.attr("transform", 'translate(0, ${paramHeight})');

			var paramWidth = (p.width() > 0 ? p.width() : this.width);
			var fObject = editor.foreignObject(param, (this.width - paramWidth) / 2, 5, paramWidth, p.height());
			p.appendTo(fObject);
			paramHeight += Std.int(p.height()) + 10;
		}

		refreshHeight();
	}

	public function dispose() {
		element.remove();
	}

	function refreshHeight() {
		var height = getNodesHeight();
		element.find(".nodes").height(height);
		element.find(".outline").attr("height", getHeight()+2);
		if (inputs.length > 1 || outputs.length > 1 || paramHeight == 0) {
			element.find(".nodes-separator").attr("y2", HEADER_HEIGHT + height);
			element.find(".nodes-separator").show();
		} else {
			element.find(".nodes-separator").hide();
		}

		if (parametersGroup != null) {
			parametersGroup.attr("transform", 'translate(0, ${HEADER_HEIGHT + height})');
			parametersGroup.find(".parameters").attr("height", paramHeight);
		}
	}

	public function setPosition(x : Float, y : Float) {
		this.x = x;
		this.y = y;
		element.attr({transform: 'translate(${x} ${y})'});
	}

	public function setSelected(b : Bool) {
		selected = b;
		element.removeClass();
		if (b) {
			element.addClass("selected");
		} else {
			element.addClass("not-selected");
		}
	}
	public function getId() {
		return this.nodeInstance.id;
	}
	public function getShaderNode() {
		return this.nodeInstance;
	}
	public function getX() {
		return this.x;
	}
	public function getY() {
		return this.y;
	}
	public function getWidth() {
		return this.width;
	}
	public function getNodesHeight() {
		var maxNb = Std.int(Math.max(inputs.length, outputs.length));
		if (maxNb == 1 && paramHeight > 0) {
			return 0;
		}
		return (NODE_MARGIN + NODE_RADIUS) * (maxNb+1);
	}
	public function getHeight() {
		return HEADER_HEIGHT + getNodesHeight() + paramHeight;
	}
	public function getElement() {
		return element;
	}
}