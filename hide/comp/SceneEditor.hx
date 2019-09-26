package hide.comp;

import hrt.prefab.terrain.Terrain;
import h3d.scene.Mesh;
import h3d.col.FPoint;
import h3d.col.Ray;
import h3d.col.PolygonBuffer;
import h3d.prim.HMDModel;
import h3d.col.Collider.OptimizedCollider;
import h3d.Vector;
import hxd.Key as K;
import hxd.Math as M;

import hrt.prefab.Prefab as PrefabElement;
import hrt.prefab.Object3D;
import h3d.scene.Object;

@:access(hide.comp.SceneEditor)
class SceneEditorContext extends hide.prefab.EditContext {

	public var editor(default, null) : SceneEditor;
	public var elements : Array<PrefabElement>;
	public var rootObjects(default, null): Array<Object>;
	public var rootElements(default, null): Array<PrefabElement>;

	public function new(ctx, elts, editor) {
		super(ctx);
		this.editor = editor;
		this.updates = editor.updates;
		this.elements = elts;
		rootObjects = [];
		rootElements = [];
		cleanups = [];
		for(elt in elements) {
			// var obj3d = elt.to(Object3D);
			// if(obj3d == null) continue;
			if(!SceneEditor.hasParent(elt, elements)) {
				rootElements.push(elt);
				var ctx = getContext(elt);
				if(ctx != null) {
					var pobj = elt.parent == editor.sceneData ? ctx.shared.root3d : getContextRec(elt.parent).local3d;
					if( ctx.local3d != pobj )
						rootObjects.push(ctx.local3d);
				}
			}
		}
	}

	override function getCurrentProps( p : hrt.prefab.Prefab ) {
		var cur = editor.curEdit;
		return cur != null && cur.elements[0] == p ? editor.properties.element : new Element();
	}

	function getContextRec( p : hrt.prefab.Prefab ) {
		if( p == null )
			return editor.context;
		var c = editor.context.shared.contexts.get(p);
		if( c == null )
			return getContextRec(p.parent);
		return c;
	}

	override function rebuildProperties() {
		editor.scene.setCurrent();
		editor.selectObjects(elements);
	}

	override function rebuildPrefab( p : hrt.prefab.Prefab ) {
		// refresh all for now
		editor.refresh();
	}

	public function cleanup() {
		for( c in cleanups.copy() )
			c();
		cleanups = [];
	}

	override function onChange(p : PrefabElement, pname: String) {
		super.onChange(p, pname);
		editor.onPrefabChange(p, pname);
	}
}

enum RefreshMode {
	Partial;
	Full;
}

typedef CustomPivot = { elt : PrefabElement, mesh : Mesh, locPos : Vector };

class SceneEditor {

	public var tree : hide.comp.IconTree<PrefabElement>;
	public var favTree : hide.comp.IconTree<PrefabElement>;
	public var scene : hide.comp.Scene;
	public var properties : hide.comp.PropsEditor;
	public var context(default,null) : hrt.prefab.Context;
	public var curEdit(default, null) : SceneEditorContext;
	public var snapToGround = false;
	public var localTransform = true;
	public var cameraController : h3d.scene.CameraController;
	public var editorDisplay(default,set) : Bool;

	var searchBox : Element;
	var updates : Array<Float -> Void> = [];
	
	var hideGizmo = false;
	var gizmo : hide.view.l3d.Gizmo;
	static var customPivot : CustomPivot;
	var interactives : Map<PrefabElement, h3d.scene.Interactive>;
	var ide : hide.Ide;
	public var event(default, null) : hxd.WaitEvent;
	var hideList : Map<PrefabElement, Bool> = new Map();
	var lockList : Map<PrefabElement, Bool> = new Map();
	var favorites : Array<PrefabElement> = [];

	var undo(get, null):hide.ui.UndoHistory;
	function get_undo() { return view.undo; }

	public var view(default, null) : hide.view.FileView;
	var sceneData : PrefabElement;

	public function new(view, data) {
		ide = hide.Ide.inst;
		this.view = view;
		this.sceneData = data;

		event = new hxd.WaitEvent();

		var propsEl = new Element('<div class="props"></div>');
		properties = new hide.comp.PropsEditor(undo,null,propsEl);
		properties.saveDisplayKey = view.saveDisplayKey + "/properties";

		tree = new hide.comp.IconTree();
		tree.async = false;
		tree.autoOpenNodes = false;

		favTree = new hide.comp.IconTree();
		favTree.async = false;
		favTree.autoOpenNodes = false;

		var sceneEl = new Element('<div class="heaps-scene"></div>');
		scene = new hide.comp.Scene(view.config, null, sceneEl);
		scene.editor = this;
		scene.onReady = onSceneReady;
		scene.onResize = function() {
			context.shared.root2d.x = scene.width >> 1;
			context.shared.root2d.y = scene.height >> 1;
			onResize();
		};

		context = new hrt.prefab.Context();
		context.shared = new hide.prefab.ContextShared(scene);
		context.shared.currentPath = view.state.path;
		context.init();
		editorDisplay = true;

		view.keys.register("copy", onCopy);
		view.keys.register("paste", onPaste);
		view.keys.register("cancel", deselect);
		view.keys.register("selectAll", selectAll);
		view.keys.register("duplicate", duplicate.bind(true));
		view.keys.register("duplicateInPlace", duplicate.bind(false));
		view.keys.register("group", groupSelection);
		view.keys.register("delete", () -> deleteElements(curEdit.rootElements));
		view.keys.register("search", function() {
			if(searchBox != null) {
				searchBox.show();
				searchBox.find("input").focus().select();
			}
		});
		view.keys.register("rename", function () {
			if(curEdit.rootElements.length > 0)
				tree.editNode(curEdit.rootElements[0]);
		});

		view.keys.register("sceneeditor.focus", focusSelection);
		view.keys.register("sceneeditor.lasso", startLassoSelect);
		view.keys.register("sceneeditor.hide", function() {
			var isHidden = isHidden(curEdit.rootElements[0]);
			setVisible(curEdit.elements, isHidden);
		});
		view.keys.register("sceneeditor.isolate", function() {	isolate(curEdit.elements); });
		view.keys.register("sceneeditor.showAll", function() {	setVisible(context.shared.elements(), true); });
		view.keys.register("sceneeditor.selectParent", function() {
			if(curEdit.rootElements.length > 0)
				selectObjects([curEdit.rootElements[0].parent]);
		});
		view.keys.register("sceneeditor.reparent", function() {
			if(curEdit.rootElements.length > 1) {
				var children = curEdit.rootElements.copy();
				var parent = children.pop();
				reparentElement(children, parent, 0);
			}
		});
		view.keys.register("sceneeditor.editPivot", editPivot);

		// Load display state
		{
			var all = sceneData.flatten(hrt.prefab.Prefab);
			var list = @:privateAccess view.getDisplayState("hideList");
			if(list != null) {
				var m = [for(i in (list:Array<Dynamic>)) i => true];
				for(p in all) {
					if(m.exists(p.getAbsPath()))
						hideList.set(p, true);
				}
			}
			var list = @:privateAccess view.getDisplayState("lockList");
			if(list != null) {
				var m = [for(i in (list:Array<Dynamic>)) i => true];
				for(p in all) {
					if(m.exists(p.getAbsPath()))
						lockList.set(p, true);
				}
			}
			var favList = @:privateAccess view.getDisplayState("favorites");
			if(favList != null) {
				for(p in all) {
					if(favList.indexOf(p.getAbsPath()) >= 0)
						favorites.push(p);
				}
			}
		}
	}

	public function onResourceChanged(lib : hxd.fmt.hmd.Library) {

		var models = sceneData.findAll(p -> Std.downcast(p, PrefabElement));
		var toRebuild : Array<PrefabElement> = [];
		for(m in models) {
			@:privateAccess if(m.source == lib.resource.entry.path) {
				if (toRebuild.indexOf(m) < 0) {
					toRebuild.push(m);
				}
			}
		}

		for(m in toRebuild) {
			removeInstance(m);
			makeInstance(m);
		}
	}

	public dynamic function onResize() {
	}

	function set_editorDisplay(v) {
		context.shared.editorDisplay = v;
		return editorDisplay = v;
	}

	public function getSelection() {
		return curEdit != null ? curEdit.elements : [];
	}

	public function addSearchBox(parent : Element) {
		searchBox = new Element("<div>").addClass("searchBox").appendTo(parent);
		new Element("<input type='text'>").appendTo(searchBox).keydown(function(e) {
			if( e.keyCode == 27 ) {
				searchBox.find("i").click();
				return;
			}
		}).keyup(function(e) {
			tree.searchFilter(e.getThis().val());
		});
		new Element("<i>").addClass("fa fa-times-circle").appendTo(searchBox).click(function(_) {
			tree.searchFilter(null);
			searchBox.toggle();
		});
	}

	function makeCamController() {
		var c = new h3d.scene.CameraController(scene.s3d);
		c.friction = 0.9;
		c.panSpeed = 0.6;
		c.zoomAmount = 1.05;
		c.smooth = 0.7;
		return c;
	}

	function focusSelection() {
		if(curEdit.rootObjects.length > 0) {
			var bnds = new h3d.col.Bounds();
			var centroid = new h3d.Vector();
			for(obj in curEdit.rootObjects) {
				centroid = centroid.add(obj.getAbsPos().getPosition());
				bnds.add(obj.getBounds());
			}
			if(!bnds.isEmpty()) {
				var s = bnds.toSphere();
				cameraController.set(s.r * 4.0, null, null, s.getCenter());
			}
			else {
				centroid.scale3(1.0 / curEdit.rootObjects.length);
				cameraController.set(centroid.toPoint());
			}
		}
		for(obj in curEdit.rootElements)
			tree.revealNode(obj);
	}

	function onSceneReady() {

		tree.saveDisplayKey = view.saveDisplayKey + '/tree';

		scene.s2d.addChild(context.shared.root2d);
		scene.s3d.addChild(context.shared.root3d);

		gizmo = new hide.view.l3d.Gizmo(scene);
		gizmo.moveStep = view.config.get("sceneeditor.gridSnapStep");

		cameraController = makeCamController();

		resetCamera();

		var cam = @:privateAccess view.getDisplayState("Camera");
		if( cam != null ) {
			scene.s3d.camera.pos.set(cam.x, cam.y, cam.z);
			scene.s3d.camera.target.set(cam.tx, cam.ty, cam.tz);
		}
		cameraController.loadFromCamera();
		scene.onUpdate = update;

		// BUILD scene tree

		function makeItem(o:PrefabElement, ?state) : hide.comp.IconTree.IconTreeItem<PrefabElement> {
			var p = o.getHideProps();
			var r : hide.comp.IconTree.IconTreeItem<PrefabElement> = {
				value : o,
				text : o.name,
				icon : "fa fa-"+p.icon,
				children : o.children.length > 0,
				state: state
			};
			return r;
		}
		favTree.get = function (o:PrefabElement) {
			if(o == null) {
				return [for(f in favorites) makeItem(f, {
					disabled: true
				})];
			}
			return [];
		}
		favTree.allowRename = false;
		favTree.init();
		favTree.onAllowMove = function(_, _) {
			return false;
		};
		favTree.onClick = function(e, evt) {
			if(evt.ctrlKey) {
				var sel = tree.getSelection();
				sel.push(e);
				selectObjects(sel, true);
				tree.revealNode(e);
			}
			else
				selectObjects([e], true);
		}
		favTree.onDblClick = function(e) {
			selectObjects([e], true);
			tree.revealNode(e);
			return true;
		}
		tree.get = function(o:PrefabElement) {
			var objs = o == null ? sceneData.children : Lambda.array(o);
			var out = [for( o in objs ) makeItem(o)];
			return out;
		};
		function ctxMenu(tree, e) {
			e.preventDefault();
			var current = tree.getCurrentOver();
			if(current != null && (curEdit == null || curEdit.elements.indexOf(current) < 0)) {
				selectObjects([current]);
			}

			var newItems = getNewContextMenu(current);
			var menuItems : Array<hide.comp.ContextMenu.ContextMenuItem> = [
				{ label : "New...", menu : newItems },
			];
			var actionItems : Array<hide.comp.ContextMenu.ContextMenuItem> = [
				{ label : "Favorite", checked : current != null && isFavorite(current), click : function() setFavorite(current, !isFavorite(current)) },
				{ label : "Rename", enabled : current != null, click : function() tree.editNode(current) },
				{ label : "Delete", enabled : current != null, click : function() deleteElements(curEdit.rootElements) },
				{ label : "Duplicate", enabled : current != null, click : duplicate.bind(false) },
				{ label : "Reference", enabled : current != null, click : function() createRef(current, current.parent) },
			];

			if(current != null && current.to(Object3D) != null && current.to(hrt.prefab.Reference) == null) {
				var visible = !isHidden(current);
				var locked = isLocked(current);
				menuItems = menuItems.concat([
					{ label : "Visible", checked : visible, click : function() setVisible(curEdit.elements, !visible) },
					{ label : "Locked", checked : locked, click : function() setLock(curEdit.elements, locked) },
					{ label : "Select all", click : selectAll },
					{ label : "Select children", enabled : current != null, click : function() selectObjects(current.flatten()) },
				]);
				actionItems = actionItems.concat([
					{ label : "Isolate", click : function() isolate(curEdit.elements) },
					{ label : "Group", enabled : curEdit != null && canGroupSelection(), click : groupSelection }
				]);
			}
			else if(current != null) {
				var enabled = current.enabled;
				menuItems.push({ label : "Enable", checked : enabled, click : function() setEnabled(curEdit.elements, !enabled) });
			}

			menuItems.push({ isSeparator : true, label : "" });
			new hide.comp.ContextMenu(menuItems.concat(actionItems));
		};
		tree.element.parent().contextmenu(ctxMenu.bind(tree));
		favTree.element.parent().contextmenu(ctxMenu.bind(favTree));
		tree.allowRename = true;
		tree.init();
		tree.onClick = function(e, _) {
			selectObjects(tree.getSelection(), false);
		}
		tree.onDblClick = function(e) {
			focusSelection();
			return true;
		}
		tree.onRename = function(e, name) {
			var oldName = e.name;
			e.name = name;
			undo.change(Field(e, "name", oldName), function() {
				tree.refresh();
				refreshScene();
			});
			refreshScene();
			return true;
		};
		tree.onAllowMove = function(_, _) {
			return true;
		};

		// Batch tree.onMove, which is called for every node moved, causing problems with undo and refresh
		{
			var movetimer : haxe.Timer = null;
			var moved = [];
			tree.onMove = function(e, to, idx) {
				if(movetimer != null) {
					movetimer.stop();
				}
				moved.push(e);
				movetimer = haxe.Timer.delay(function() {
					reparentElement(moved, to, idx);
					movetimer = null;
					moved = [];
				}, 50);
			}
		}
		tree.applyStyle = applyTreeStyle;
		selectObjects([]);
		refresh();
	}

	public function refresh( ?mode: RefreshMode, ?callb: Void->Void) {
		if(mode == null || mode == Full) refreshScene();
		refreshFavs();
		refreshTree(callb);
	}

	public function collapseTree() {
		tree.collapseAll();
		for(fav in favorites)
			tree.openNode(fav);
	}

	function refreshTree( ?callb ) {
		tree.refresh(function() {
			var all = sceneData.flatten(hrt.prefab.Prefab);
			for(elt in all) {
				var el = tree.getElement(elt);
				if(el == null) continue;
				applyTreeStyle(elt, el);
			}
			if(callb != null) callb();
		});
	}

	function refreshFavs() {
		favTree.refresh();
	}

	function refreshProps() {
		selectObjects(curEdit.elements, false);
	}

	public function refreshScene() {
		var sh = context.shared;
		sh.root3d.remove();
		sh.root2d.remove();
		for( c in sh.contexts )
			if( c != null && c.cleanup != null )
				c.cleanup();
		context.shared = sh = new hide.prefab.ContextShared(scene);
		sh.editorDisplay = editorDisplay;
		sh.currentPath = view.state.path;
		scene.s3d.addChild(sh.root3d);
		scene.s2d.addChild(sh.root2d);
		scene.setCurrent();
		scene.onResize();
		context.init();
		sceneData.make(context);
		var bgcol = scene.engine.backgroundColor;
		scene.init();
		scene.engine.backgroundColor = bgcol;
		refreshInteractives();

		var all = sceneData.flatten(hrt.prefab.Prefab);
		for(elt in all)
			applySceneStyle(elt);
		onRefresh();
	}

	public dynamic function onRefresh() {
	}

	function makeInteractive(elt: PrefabElement) {
		var obj3d = Std.downcast(elt, Object3D);
		if(obj3d == null)
			return;

		// Disable Interactive for the terrain
		var terrain = Std.downcast(elt, Terrain);
		if(terrain != null)
			return;

		var contexts = context.shared.contexts;
		var ctx = contexts[elt];
		if(ctx == null)
			return;
		var local3d = ctx.local3d;
		if(local3d == null)
			return;
		var meshes = context.shared.getObjects(elt, h3d.scene.Mesh);
		var invRootMat = local3d.getAbsPos().clone();
		invRootMat.invert();
		var bounds = new h3d.col.Bounds();
		for(mesh in meshes) {
			if(mesh.ignoreCollide)
				continue;
			// invisible objects are ignored collision wise
			var p : h3d.scene.Object = mesh;
			while( p != local3d ) {
				if( !p.visible ) break;
				p = p.parent;
			}
			if( p != local3d ) continue;
			var localMat = mesh.getAbsPos().clone();
			localMat.multiply(localMat, invRootMat);
			var lb = mesh.primitive.getBounds().clone();
			lb.transform(localMat);
			bounds.add(lb);
		}
		var meshCollider = new h3d.col.Collider.GroupCollider([for(m in meshes) {
			var c : h3d.col.Collider = try m.getGlobalCollider() catch(e: Dynamic) null;
			if(c != null) c;
		}]);
		var boundsCollider = new h3d.col.ObjectCollider(local3d, bounds);
		var r = Math.max(bounds.getSize().z, Math.max(bounds.getSize().x, bounds.getSize().y));
		var pos = local3d.getAbsPos();
		local3d.cullingCollider = new h3d.col.Sphere(pos.tx, pos.ty, pos.tz, r);
		var int = new h3d.scene.Interactive(boundsCollider, local3d);
		interactives.set(elt, int);
		int.ignoreParentTransform = true;
		int.preciseShape = meshCollider;
		int.propagateEvents = true;
		int.enableRightButton = true;
		int.ignoreMoveEvents = local3d.parent != null && Std.is(local3d.parent, hrt.prefab.l3d.SprayObject);
		var startDrag = null;
		var dragBtn = -1;
		int.onClick = function(e) {
			if(e.button == K.MOUSE_RIGHT) {
				e.propagate = false;
				var parentEl = curEdit.rootElements[0];
				if(parentEl == null)
					parentEl = elt;
				var group = getParentGroup(parentEl);
				if(group != null)
					parentEl = group;
				var newItems = getNewContextMenu(parentEl, function(newElt) {
					var newObj3d = Std.downcast(newElt, Object3D);
					if(newObj3d != null) {
						var newPos = new h3d.Matrix();
						newPos.identity();
						newPos.setPosition(@:privateAccess int.hitPoint);
						var invParent = getObject(parentEl).getAbsPos().clone();
						invParent.invert();
						newPos.multiply(newPos, invParent);
						newObj3d.setTransform(newPos);
					}
				});
				var menuItems : Array<hide.comp.ContextMenu.ContextMenuItem> = [
					{ label : "New...", menu : newItems },
				];
				new hide.comp.ContextMenu(menuItems);
			}
		}
		int.onPush = function(e) {
			startDrag = [scene.s2d.mouseX, scene.s2d.mouseY];
			dragBtn = e.button;
			if(e.button != K.MOUSE_LEFT)
				return;
			e.propagate = false;
			var elts = null;
			if(K.isDown(K.SHIFT)) {
				if(Type.getClass(elt.parent) == hrt.prefab.Object3D)
					elts = [elt.parent];
				else
					elts = elt.parent.children;
			}
			else
				elts = [elt];

			if(K.isDown(K.CTRL)) {
				var current = curEdit.elements.copy();
				if(current.indexOf(elt) < 0) {
					for(e in elts) {
						if(current.indexOf(e) < 0)
							current.push(e);
					}
				}
				else {
					for(e in elts)
						current.remove(e);
				}
				selectObjects(current);
			}
			else
				selectObjects(elts);
		}
		int.onRelease = function(e) {
			startDrag = null;
			dragBtn = -1;
			if(e.button == K.MOUSE_LEFT) {
				e.propagate = false;
			}
		}
		int.onMove = function(e) {
			if(startDrag != null) {
				if((M.abs(startDrag[0] - scene.s2d.mouseX) + M.abs(startDrag[1] - scene.s2d.mouseY)) > 5) {
					int.preventClick();
					startDrag = null;
					if(dragBtn == K.MOUSE_LEFT) {
						moveGizmoToSelection();
						gizmo.startMove(MoveXY);
					}
				}
			}
		}
	}

	public function refreshInteractive(elt : PrefabElement) {
		var int = interactives.get(elt);
		if(int != null) {
			int.remove();
			interactives.remove(elt);
		}
		makeInteractive(elt);
	}

	function refreshInteractives() {
		var contexts = context.shared.contexts;
		interactives = new Map();
		var all = contexts.keys();
		for(elt in all) {
			makeInteractive(elt);
		}
	}

	function setupGizmo() {
		if(curEdit == null) return;
		gizmo.onStartMove = function(mode) {
			var objects3d = [for(o in curEdit.rootElements) {
				var obj3d = o.to(hrt.prefab.Object3D);
				if(obj3d != null)
					obj3d;
			}];
			var sceneObjs = [for(o in objects3d) getContext(o).local3d];
			var pivotPt = getPivot(sceneObjs);
			var pivot = new h3d.Matrix();
			pivot.initTranslation(pivotPt.x, pivotPt.y, pivotPt.z);
			var invPivot = pivot.clone();
			invPivot.invert();

			var localMats = [for(o in sceneObjs) {
				var m = worldMat(o);
				m.multiply(m, invPivot);
				m;
			}];

			var posQuant = view.config.get("sceneeditor.xyzPrecision");
			var scaleQuant = view.config.get("sceneeditor.scalePrecision");
			var rotQuant = view.config.get("sceneeditor.rotatePrecision");

			inline function quantize(x: Float, step: Float) {
				if(step > 0) {
					x = Math.round(x / step) * step;
					x = untyped parseFloat(x.toFixed(5)); // Snap to closest nicely displayed float :cold_sweat:
				}
				return x;
			}

			var prevState = [for(o in objects3d) o.saveTransform()];
			gizmo.onMove = function(translate: h3d.Vector, rot: h3d.Quat, scale: h3d.Vector) {
				var transf = new h3d.Matrix();
				transf.identity();
				if(rot != null)
					rot.toMatrix(transf);
				if(translate != null)
					transf.translate(translate.x, translate.y, translate.z);
				for(i in 0...sceneObjs.length) {
					var newMat = localMats[i].clone();
					newMat.multiply(newMat, transf);
					newMat.multiply(newMat, pivot);
					if(snapToGround && mode == MoveXY) {
						newMat.tz = getZ(newMat.tx, newMat.ty);
					}
					var invParent = sceneObjs[i].parent.getAbsPos().clone();
					invParent.invert();
					newMat.multiply(newMat, invParent);
					if(scale != null) {
						newMat.prependScale(scale.x, scale.y, scale.z);
					}
					var obj3d = objects3d[i];
					var rot = newMat.getEulerAngles();
					obj3d.x = quantize(newMat.tx, posQuant);
					obj3d.y = quantize(newMat.ty, posQuant);
					obj3d.z = quantize(newMat.tz, posQuant);
					obj3d.rotationX = quantize(M.radToDeg(rot.x), rotQuant);
					obj3d.rotationY = quantize(M.radToDeg(rot.y), rotQuant);
					obj3d.rotationZ = quantize(M.radToDeg(rot.z), rotQuant);
					if(scale != null) {
						inline function scaleSnap(x: Float) {
							if(K.isDown(K.CTRL)) {
								var step = K.isDown(K.SHIFT) ? 0.5 : 1.0;
								x = Math.round(x / step) * step;
							}
							return x;
						}
						var s = newMat.getScale();
						obj3d.scaleX = quantize(scaleSnap(s.x), scaleQuant);
						obj3d.scaleY = quantize(scaleSnap(s.y), scaleQuant);
						obj3d.scaleZ = quantize(scaleSnap(s.z), scaleQuant);
					}
					obj3d.applyPos(sceneObjs[i]);
				}
			}

			gizmo.onFinishMove = function() {
				var newState = [for(o in objects3d) o.saveTransform()];
				refreshProps();
				undo.change(Custom(function(undo) {
					if( undo ) {
						for(i in 0...objects3d.length) {
							objects3d[i].loadTransform(prevState[i]);
							objects3d[i].applyPos(sceneObjs[i]);
						}
						refreshProps();
					} else {
						for(i in 0...objects3d.length) {
							objects3d[i].loadTransform(newState[i]);
							objects3d[i].applyPos(sceneObjs[i]);
						}
						refreshProps();
					}
					for(o in objects3d)
						o.updateInstance(getContext(o));
				}));
				for(o in objects3d)
					o.updateInstance(getContext(o));
        for(i in 0...objects3d.length) {
					var sprayObj = Std.downcast(sceneObjs[i].parent, hrt.prefab.l3d.SprayObject);
					if(sprayObj != null) {
						@:privateAccess sprayObj.blockHead = null;
					}
				}
			}
		}
	}

	function moveGizmoToSelection() {
		// Snap Gizmo at center of objects
		gizmo.getRotationQuat().identity();
		if(curEdit != null && curEdit.rootObjects.length > 0) {
			var pos = getPivot(curEdit.rootObjects);
			gizmo.visible = hideGizmo ? false : true;
			gizmo.setPosition(pos.x, pos.y, pos.z);

			if(curEdit.rootObjects.length == 1 && (localTransform || K.isDown(K.ALT))) {
				var obj = curEdit.rootObjects[0];
				var mat = worldMat(obj);
				var s = mat.getScale();
				if(s.x != 0 && s.y != 0 && s.z != 0) {
					mat.prependScale(1.0 / s.x, 1.0 / s.y, 1.0 / s.z);
					gizmo.getRotationQuat().initRotateMatrix(mat);
				}
			}
		}
		else {
			gizmo.visible = false;
		}
	}

	var inLassoMode = false;
	function startLassoSelect() {
		if(inLassoMode) {
			inLassoMode = false;
			return;
		}
		inLassoMode = true;
		var g = new h2d.Object(scene.s2d);
		var overlay = new h2d.Bitmap(h2d.Tile.fromColor(0xffffff, 10000, 10000, 0.1), g);
		var intOverlay = new h2d.Interactive(10000, 10000, scene.s2d);
		var lastPt = new h2d.col.Point(scene.s2d.mouseX, scene.s2d.mouseY);
		var points : h2d.col.Polygon = [lastPt];
		var polyG = new h2d.Graphics(g);
		event.waitUntil(function(dt) {
			var curPt = new h2d.col.Point(scene.s2d.mouseX, scene.s2d.mouseY);
			if(curPt.distance(lastPt) > 3.0) {
				points.push(curPt);
				polyG.clear();
				polyG.beginFill(0xff0000, 0.5);
				polyG.lineStyle(1.0, 0, 1.0);
				polyG.moveTo(points[0].x, points[0].y);
				for(i in 1...points.length) {
					polyG.lineTo(points[i].x, points[i].y);
				}
				polyG.endFill();
				lastPt = curPt;
			}

			var finish = false;
			if(!inLassoMode || K.isDown(K.ESCAPE) || K.isDown(K.MOUSE_RIGHT)) {
				finish = true;
			}

			if(K.isDown(K.MOUSE_LEFT)) {
				var contexts = context.shared.contexts;
				var all = getAllSelectable();
				var inside = [];
				for(elt in all) {
					if(elt.to(Object3D) == null)
						continue;
					var ctx = contexts[elt];
					var o = ctx.local3d;
					if(o == null || !o.visible)
						continue;
					var absPos = o.getAbsPos();
					var screenPos = worldToScreen(absPos.tx, absPos.ty, absPos.tz);
					if(points.contains(screenPos, false)) {
						inside.push(elt);
					}
				}
				selectObjects(inside);
				finish = true;
			}

			if(finish) {
				intOverlay.remove();
				g.remove();
				inLassoMode = false;
				return true;
			}
			return false;
		});
	}

	public function onPrefabChange(p: PrefabElement, ?pname: String) {
		var model = p.to(hrt.prefab.Model);
		if(model != null && pname == "source") {
			refreshScene();
			return;
		}

		if(p != sceneData) {
			var el = tree.getElement(p);
			applyTreeStyle(p, el);
		}

		applySceneStyle(p);
	}

	public function applyTreeStyle(p: PrefabElement, el: Element) {
		var obj3d  = p.to(Object3D);
		el.toggleClass("disabled", !p.enabled);
		el.find("a").first().toggleClass("favorite", isFavorite(p));

		if(obj3d != null) {
			el.toggleClass("disabled", !obj3d.visible);
			el.toggleClass("hidden", isHidden(obj3d));
			el.toggleClass("locked", isLocked(obj3d));
			var visTog = el.find(".visibility-toggle").first();
			if(visTog.length == 0) {
				visTog = new Element('<i class="fa fa-eye visibility-toggle"/>').insertAfter(el.find("a.jstree-anchor").first());
				visTog.click(function(e) {
					if(curEdit.elements.indexOf(obj3d) >= 0)
						setVisible(curEdit.elements, isHidden(obj3d));
					else
						setVisible([obj3d], isHidden(obj3d));

					e.preventDefault();
					e.stopPropagation();
				});
				visTog.dblclick(function(e) {
					e.preventDefault();
					e.stopPropagation();
				});
			}
			var lockTog = el.find(".lock-toggle").first();
			if(lockTog.length == 0) {
				lockTog = new Element('<i class="fa fa-lock lock-toggle"/>').insertAfter(el.find("a.jstree-anchor").first());
				lockTog.click(function(e) {
					if(curEdit.elements.indexOf(obj3d) >= 0)
						setLock(curEdit.elements, isLocked(obj3d));
					else
						setLock([obj3d], isLocked(obj3d));

					e.preventDefault();
					e.stopPropagation();
				});
				lockTog.dblclick(function(e) {
					e.preventDefault();
					e.stopPropagation();
				});
			}
			lockTog.css({visibility: (isLocked(obj3d) ? "visible" : "hidden")});
		}
	}

	public function applySceneStyle(p: PrefabElement) {
		var obj3d = p.to(Object3D);
		if(obj3d != null) {
			var visible = obj3d.visible && !isHidden(obj3d);
			for(ctx in getContexts(obj3d)) {
				ctx.local3d.visible = visible;
			}
		}
	}

	public function getInteractives(elt : PrefabElement) {
		var r = [getInteractive(elt)];
		for(c in elt.children) {
			r = r.concat(getInteractives(c));
		}
		return r;
	}

	public function getInteractive(elt: PrefabElement) {
		return interactives.get(elt);
	}

	public function getContext(elt : PrefabElement) {
		if(elt == null) return null;
		var ctx = null;
		if(elt == sceneData) {
			ctx = context.shared.contexts.get(sceneData);
			if(ctx != null) return ctx; // Some libs make their own instances
			return context;
		}
		return context.shared.contexts.get(elt);
	}

	public function getContexts(elt: PrefabElement) {
		if(elt == null)
			return null;
		return context.shared.getContexts(elt);
	}

	public function getObject(elt: PrefabElement) {
		var ctx = getContext(elt);
		if(ctx != null)
			return ctx.local3d;
		return context.shared.root3d;
	}

	public function getSelfObject(elt: PrefabElement) {
		var ctx = getContext(elt);
		var parentCtx = getContext(elt.parent);
		if(ctx == null || parentCtx == null) return null;
		if(ctx.local3d != parentCtx.local3d)
			return ctx.local3d;
		return null;
	}

	function removeInstance(elt : PrefabElement) {
		var result = true;
		var contexts = context.shared.contexts;
		function recRemove(e: PrefabElement) {
			for(c in e.children)
				recRemove(c);

			var int = interactives.get(e);
			if(int != null) {
				int.remove();
				interactives.remove(e);
			}
			for(ctx in getContexts(e)) {
				if(!e.removeInstance(ctx))
					result = false;
				contexts.remove(e);
			}
		}
		recRemove(elt);
		return result;
	}

	function makeInstance(elt: PrefabElement) {
		scene.setCurrent();
		var parentCtx = getContext(elt.parent);
		var ctx = elt.make(parentCtx);
		for( p in elt.flatten() ) {
			makeInteractive(p);
		}
		scene.init(ctx.local3d);
	}

	public function addObject(elts : Array<PrefabElement>) {
		for (e in elts) {
			makeInstance(e);
		}
		refresh(Partial, () -> selectObjects(elts));
		undo.change(Custom(function(undo) {
			var fullRefresh = false;
			if(undo) {
				deselect();
				for (e in elts) {
					if(!removeInstance(e))
						fullRefresh = true;
					e.parent.children.remove(e);
				}
				refresh(fullRefresh ? Full : Partial);
			}
			else {
				for (e in elts) {
					e.parent.children.push(e);
					makeInstance(e);
				}
				refresh(Partial, () -> selectObjects(elts));
			}
		}));
	}

	function fillProps( edit, e : PrefabElement ) {
		e.edit(edit);
	}

	public function showProps(e: PrefabElement) {
		scene.setCurrent();
		var edit = makeEditContext([e]);
		properties.clear();
		fillProps(edit, e);
	}

	function setObjectSelected( p : PrefabElement, ctx : hrt.prefab.Context, b : Bool ) {
		hideGizmo = false;
		p.setSelected(ctx, b);
	}

	public function selectObjects( elts : Array<PrefabElement>, ?includeTree=true) {
		scene.setCurrent();
		if( curEdit != null )
			curEdit.cleanup();
		var edit = makeEditContext(elts);
		if (elts.length == 0 || (customPivot != null && customPivot.elt != edit.rootElements[0])) {
			customPivot = null;
		}
		properties.clear();
		if( elts.length > 0 ) fillProps(edit, elts[0]);

		if(includeTree) {
			tree.setSelection(elts);
		}

		var map = new Map<PrefabElement,Bool>();
		function selectRec(e : PrefabElement, b:Bool) {
			if( map.exists(e) )
				return;
			map.set(e, true);
			var ectx = context.shared.contexts.get(e);
			setObjectSelected(e, ectx == null ? context : ectx, b);
			for( e in e.children )
				selectRec(e,b);
		}

		for( e in elts )
			selectRec(e, true);

		edit.cleanups.push(function() {
			for( e in map.keys() ) {
				if( hasBeenRemoved(e) ) continue;
				var ectx = context.shared.contexts.get(e);
				setObjectSelected(e, ectx == null ? context : ectx, false);
			}
		});

		curEdit = edit;
		setupGizmo();
	}

	function hasBeenRemoved( e : hrt.prefab.Prefab ) {
		while( e != null && e != sceneData ) {
			if( e.parent != null && e.parent.children.indexOf(e) < 0 )
				return true;
			e = e.parent;
		}
		return e == null;
	}

	public function resetCamera() {
		scene.s3d.camera.zNear = scene.s3d.camera.zFar = 0;
		scene.resetCamera(1.5);
		cameraController.lockZPlanes = scene.s3d.camera.zNear != 0;
		cameraController.loadFromCamera();
	}

	public function getPickTransform(parent: PrefabElement) {
		var proj = screenToWorld(scene.s2d.mouseX, scene.s2d.mouseY);
		if(proj == null) return null;

		var localMat = new h3d.Matrix();
		localMat.initTranslation(proj.x, proj.y, proj.z);

		if(parent == null)
			return localMat;

		var parentMat = worldMat(getObject(parent));
		parentMat.invert();

		localMat.multiply(localMat, parentMat);
		return localMat;
	}

	public function dropObjects(paths: Array<String>, parent: PrefabElement) {
		var localMat = getPickTransform(parent);
		if(localMat == null) return;

		localMat.tx = hxd.Math.round(localMat.tx);
		localMat.ty = hxd.Math.round(localMat.ty);
		localMat.tz = hxd.Math.round(localMat.tz);

		var elts: Array<PrefabElement> = [];
		for(path in paths) {
			var obj3d : Object3D;
			var relative = ide.makeRelative(path);

			if(hrt.prefab.Library.getPrefabType(path) != null) {
				var ref = new hrt.prefab.Reference(parent);
				ref.refpath = "/" + relative;
				obj3d = ref;
				obj3d.name = new haxe.io.Path(relative).file;
			}
			else {
				obj3d = new hrt.prefab.Model(parent);
				obj3d.source = relative;
			}
			obj3d.setTransform(localMat);
			autoName(obj3d);
			elts.push(obj3d);

		}

		for(e in elts)
			makeInstance(e);
		refresh(Partial, () -> selectObjects(elts));

		undo.change(Custom(function(undo) {
			if( undo ) {
				var fullRefresh = false;
				for(e in elts) {
					if(!removeInstance(e))
						fullRefresh = true;
					parent.children.remove(e);
				}
				refresh(fullRefresh ? Full : Partial);
			}
			else {
				for(e in elts) {
					parent.children.push(e);
					makeInstance(e);
				}
				refresh(Partial);
			}
		}));
	}

	function canGroupSelection() {
		var elts = curEdit.rootElements;
		if(elts.length == 0)
			return false;

		if(elts.length == 1)
			return true;

		// Only allow grouping of sibling elements
		var parent = elts[0].parent;
		for(e in elts)
			if(e.parent != parent)
				return false;

		return true;
	}

	function groupSelection() {
		if(!canGroupSelection())
			return;

		var elts = curEdit.rootElements;
		var parent = elts[0].parent;
		var parentMat = worldMat(parent);
		var invParentMat = parentMat.clone();
		invParentMat.invert();


		var pivot = new h3d.Vector();
		{
			var count = 0;
			for(elt in curEdit.rootElements) {
				var m = worldMat(elt);
				if(m != null) {
					pivot = pivot.add(m.getPosition());
					++count;
				}
			}
			pivot.scale3(1.0 / count);
		}
		var local = new h3d.Matrix();
		local.initTranslation(pivot.x, pivot.y, pivot.z);
		local.multiply(local, invParentMat);
		var group = new hrt.prefab.Object3D(parent);
		@:privateAccess group.type = "object";
		autoName(group);
		group.x = local.tx;
		group.y = local.ty;
		group.z = local.tz;
		var parentCtx = getContext(parent);
		if(parentCtx == null)
			parentCtx = context;
		group.make(parentCtx);
		var groupCtx = getContext(group);

		var effectFunc = reparentImpl(elts, group, 0);
		undo.change(Custom(function(undo) {
			if(undo) {
				group.parent = null;
				context.shared.contexts.remove(group);
				effectFunc(true);
			}
			else {
				group.parent = parent;
				context.shared.contexts.set(group, groupCtx);
				effectFunc(false);
			}
			if(undo)
				refresh(deselect);
			else
				refresh(()->selectObjects([group]));
		}));
		refresh(effectFunc(false) ? Full : Partial, () -> selectObjects([group]));
	}

	function onCopy() {
		if(curEdit == null) return;
		if(curEdit.rootElements.length == 1) {
			view.setClipboard(curEdit.rootElements[0].saveData(), "prefab");
		}
		else {
			var lib = new hrt.prefab.Library();
			for(e in curEdit.rootElements) {
				lib.children.push(e);
			}
			view.setClipboard(lib.saveData(), "library");
		}
	}

	function onPaste() {
		var parent : PrefabElement = sceneData;
		if(curEdit != null && curEdit.elements.length > 0) {
			parent = curEdit.elements[0];
		}
		var obj = haxe.Json.parse(haxe.Json.stringify(view.getClipboard("prefab")));
		if(obj != null) {
			var p = hrt.prefab.Prefab.loadPrefab(obj, parent);
			autoName(p);
			refresh();
		}
		else {
			obj = view.getClipboard("library");
			if(obj != null) {
				var lib = hrt.prefab.Prefab.loadPrefab(obj);
				for(c in lib.children) {
					autoName(c);
					c.parent = parent;
				}
				refresh();
			}
		}
	}

	public function isVisible(elt: PrefabElement) {
		if(elt == sceneData)
			return true;
		var o = elt.to(Object3D);
		if(o == null)
			return true;
		return o.visible && !isHidden(o) && (elt.parent != null ? isVisible(elt.parent) : true);
	}

	public function getAllSelectable() : Array<PrefabElement> {
		var ret = [];
		for(elt in interactives.keys()) {
			var i = interactives.get(elt);
			var p : h3d.scene.Object = i;
			while( p != null && p.visible )
				p = p.parent;
			if( p != null ) continue;
			ret.push(elt);
		}
		return ret;
	}

	public function selectAll() {
		selectObjects(getAllSelectable());
	}

	public function deselect() {
		selectObjects([]);
	}

	public function isSelected( p : PrefabElement ) {
		return curEdit != null && curEdit.elements.indexOf(p) >= 0;
	}

	public function setEnabled(elements : Array<PrefabElement>, enable: Bool) {
		// Don't disable/enable Object3Ds, too confusing with visibility
		elements = [for(e in elements) if(e.to(Object3D) == null || e.to(hrt.prefab.Reference) != null) e];
		var old = [for(e in elements) e.enabled];
		function apply(on) {
			for(i in 0...elements.length) {
				elements[i].enabled = on ? enable : old[i];
				onPrefabChange(elements[i]);
			}
			refreshScene();
		}
		apply(true);
		undo.change(Custom(function(undo) {
			if(undo)
				apply(false);
			else
				apply(true);
		}));
	}

	public function isHidden(e: PrefabElement) {
		if(e == null)
			return false;
		return hideList.exists(e);
	}

	public function isLocked(e: PrefabElement) {
		if(e == null)
			return false;
		return lockList.exists(e);
	}

	function saveDisplayState() {
		var state = [for (h in hideList.keys()) h.getAbsPath()];
		@:privateAccess view.saveDisplayState("hideList", state);
		var state = [for (h in lockList.keys()) h.getAbsPath()];
		@:privateAccess view.saveDisplayState("lockList", state);
		var state = [for(f in favorites) f.getAbsPath()];
		@:privateAccess view.saveDisplayState("favorites", state);
	}

	public function isFavorite(e: PrefabElement) {
		return favorites.indexOf(e) >= 0;
	}

	public function setFavorite(e: PrefabElement, fav: Bool) {
		if(fav && !isFavorite(e))
			favorites.push(e);
		else if(!fav && isFavorite(e))
			favorites.remove(e);

		var el = tree.getElement(e);
		if(el != null)
			applyTreeStyle(e, el);

		refreshFavs();
		saveDisplayState();
	}

	public function setVisible(elements : Array<PrefabElement>, visible: Bool) {
		for(o in elements) {
			if(visible) {
				for(c in o.flatten(Object3D)) {
					hideList.remove(c);
					var el = tree.getElement(c);
					applyTreeStyle(c, el);
					applySceneStyle(c);
				}
			}
			else {
				hideList.set(o, true);
				var el = tree.getElement(o);
				applyTreeStyle(o, el);
				applySceneStyle(o);
			}
		}
		saveDisplayState();
	}

	public function setLock(elements : Array<PrefabElement>, unlocked: Bool) {
		for(o in elements) {
			if(unlocked) {
				for(c in o.flatten(Object3D)) {
					lockList.remove(c);
					var el = tree.getElement(c);
					applyTreeStyle(c, el);
					applySceneStyle(c);
				}
			}
			else {
				for(c in o.flatten(Object3D)) {
					lockList.set(c, true);
					var el = tree.getElement(c);
					applyTreeStyle(c, el);
					applySceneStyle(c);
				}
			}
		}
		saveDisplayState();
	}

	function isolate(elts : Array<PrefabElement>) {
		var toShow = elts.copy();
		var toHide = [];
		function hideSiblings(elt: PrefabElement) {
			var p = elt.parent;
			for(c in p.children) {
				var needsVisible = c == elt
					|| toShow.indexOf(c) >= 0
					|| hasChild(c, toShow);
				if(!needsVisible) {
					toHide.push(c);
				}
			}
			if(p != sceneData) {
				hideSiblings(p);
			}
		}
		for(e in toShow) {
			hideSiblings(e);
		}
		setVisible(toHide, false);
	}

	function createRef(elt: PrefabElement, toParent: PrefabElement) {
		var ref = new hrt.prefab.Reference(toParent);
		ref.name = elt.name;
		ref.refpath = elt.getAbsPath();
		var obj3d = Std.downcast(elt, Object3D);
		if(obj3d != null) {
			ref.x = obj3d.x;
			ref.y = obj3d.y;
			ref.z = obj3d.z;
			ref.scaleX = obj3d.scaleX;
			ref.scaleY = obj3d.scaleY;
			ref.scaleZ = obj3d.scaleZ;
			ref.rotationX = obj3d.rotationX;
			ref.rotationY = obj3d.rotationY;
			ref.rotationZ = obj3d.rotationZ;
		}
		addObject([ref]);
	}

	function duplicate(thenMove: Bool) {
		if(curEdit == null) return;
		var elements = curEdit.rootElements;
		if(elements == null || elements.length == 0)
			return;
		var contexts = context.shared.contexts;

		var undoes = [];
		var newElements = [];
		for(elt in elements) {
			var clone = elt.clone();
			var index = elt.parent.children.indexOf(elt) + 1;
			clone.parent = elt.parent;
			elt.parent.children.remove(clone);
			elt.parent.children.insert(index, clone);
			autoName(clone);
			makeInstance(clone);
			newElements.push(clone);

			undoes.push(function(undo) {
				if(undo) elt.parent.children.remove(clone);
				else elt.parent.children.insert(index, clone);
			});
		}

		refreshTree(function() {
			selectObjects(newElements);
			tree.setSelection(newElements);
			if(thenMove && curEdit.rootObjects.length > 0) {
				gizmo.startMove(MoveXY, true);
				gizmo.onFinishMove = function() {
					refreshProps();
				}
			}
		});

		undo.change(Custom(function(undo) {
			deselect();

			var fullRefresh = false;
			if(undo) {
				for(elt in newElements) {
					if(!removeInstance(elt)) {
						fullRefresh = true;
						break;
					}
				}
			}

			for(u in undoes) u(undo);

			if(!undo) {
				for(elt in newElements)
					makeInstance(elt);
			}

			refresh(fullRefresh ? Full : Partial);
		}));
	}

	function setTransform(elt: PrefabElement, ?mat: h3d.Matrix, ?position: h3d.Vector) {
		var obj3d = Std.downcast(elt, hrt.prefab.Object3D);
		if(obj3d == null)
			return;
		if(mat != null)
			obj3d.setTransform(mat);
		else {
			obj3d.x = position.x;
			obj3d.y = position.y;
			obj3d.z = position.z;
		}
		var ctx = getContext(obj3d);
		if(ctx != null)
			obj3d.updateInstance(ctx);
	}

	public function deleteElements(elts : Array<PrefabElement>, ?then: Void->Void) {
		var fullRefresh = false;
		var undoes = [];
		for(elt in elts) {
			if(!removeInstance(elt))
				fullRefresh = true;
			var index = elt.parent.children.indexOf(elt);
			elt.parent.children.remove(elt);
			undoes.push(function(undo) {
				if(undo) elt.parent.children.insert(index, elt);
				else elt.parent.children.remove(elt);
			});
		}

		function refreshFunc(then) {
			refresh(fullRefresh ? Full : Partial, then);
		}

		refreshFunc(then != null ? then : deselect);

		undo.change(Custom(function(undo) {
			if(!undo && !fullRefresh)
				for(e in elts) removeInstance(e);

			for(u in undoes) u(undo);

			if(undo)
				for(e in elts) makeInstance(e);

			refreshFunc(then != null ? then : selectObjects.bind(undo ? elts : []));
		}));
	}

	function reparentElement(e : Array<PrefabElement>, to : PrefabElement, index : Int) {
		if( to == null )
			to = sceneData;

		var effectFunc = reparentImpl(e, to, index);
		undo.change(Custom(function(undo) {
			refresh(effectFunc(undo) ? Full : Partial);
		}));
		refresh(effectFunc(false) ? Full : Partial);
	}

	function makeTransform(mat: h3d.Matrix) {
		var rot = mat.getEulerAngles();
		var x = mat.tx;
		var y = mat.ty;
		var z = mat.tz;
		var s = mat.getScale();
		var scaleX = s.x;
		var scaleY = s.y;
		var scaleZ = s.z;
		var rotationX = hxd.Math.radToDeg(rot.x);
		var rotationY = hxd.Math.radToDeg(rot.y);
		var rotationZ = hxd.Math.radToDeg(rot.z);
		return { x : x, y : y, z : z, scaleX : scaleX, scaleY : scaleY, scaleZ : scaleZ, rotationX : rotationX, rotationY : rotationY, rotationZ : rotationZ };
	}

	function reparentImpl(elts : Array<PrefabElement>, toElt: PrefabElement, index: Int) : Bool -> Bool {
		var effects = [];
		var fullRefresh = false;
		var toRefresh : Array<PrefabElement> = null;
		for(elt in elts) {
			var prev = elt.parent;
			var prevIndex = prev.children.indexOf(elt);

			var obj3d = elt.to(Object3D);
			var preserveTransform = Std.is(toElt, hrt.prefab.fx.Emitter) || Std.is(prev, hrt.prefab.fx.Emitter);
			var toObj = getObject(toElt);
			var obj = getObject(elt);
			var prevState = null, newState = null;
			if(obj3d != null && toObj != null && obj != null && !preserveTransform) {
				var mat = worldMat(elt);
				var parentMat = worldMat(toElt);
				parentMat.invert();
				mat.multiply(mat, parentMat);
				prevState = obj3d.saveTransform();
				newState = makeTransform(mat);
			}

			effects.push(function(undo) {
				var refresh = false;
				if( undo ) {
					refresh = !removeInstance(elt);
					elt.parent = prev;
					prev.children.remove(elt);
					prev.children.insert(prevIndex, elt);
					if(obj3d != null && prevState != null)
						obj3d.loadTransform(prevState);
				} else {
					var refresh = !removeInstance(elt);
					elt.parent = toElt;
					toElt.children.remove(elt);
					toElt.children.insert(index, elt);
					if(obj3d != null && newState != null)
						obj3d.loadTransform(newState);
				};
				if(toRefresh.indexOf(elt) < 0)
					toRefresh.push(elt);
				return refresh;
			});
		}
		return function(undo) {
			var refresh = false;
			toRefresh = [];
			for(f in effects) {
				if(f(undo))
					refresh = true;
			}
			if(!refresh) {
				for(elt in toRefresh) {
					removeInstance(elt);
					makeInstance(elt);
				}
			}
			return refresh;
		}
	}

	function autoName(p : PrefabElement) {

		var uniqueName = false;
		if( p.type == "volumetricLightmap" || p.type == "light" )
			uniqueName = true;

		var prefix = null;
		if(p.name != null && p.name.length > 0) {
			if(uniqueName)
				prefix = ~/_+[0-9]+$/.replace(p.name, "");
			else
				prefix = p.name;
		}
		else
			prefix = p.getDefaultName();

		if(uniqueName) {
			prefix += "_";
			var id = 0;
			while( sceneData.getPrefabByName(prefix + id) != null )
				id++;

			p.name = prefix + id;
		}
		else
			p.name = prefix;

		for(c in p.children) {
			autoName(c);
		}
	}

	function update(dt:Float) {
		var cam = scene.s3d.camera;
		@:privateAccess view.saveDisplayState("Camera", { x : cam.pos.x, y : cam.pos.y, z : cam.pos.z, tx : cam.target.x, ty : cam.target.y, tz : cam.target.z });
		if(gizmo != null) {
			if(!gizmo.moving) {
				moveGizmoToSelection();
			}
			gizmo.update(dt);
		}
		event.update(dt);
		for( f in updates )
			f(dt);
		onUpdate(dt);
	}

	public dynamic function onUpdate(dt:Float) {
	}

	// Override
	function makeEditContext(elts : Array<PrefabElement>) : SceneEditorContext {
		var edit = new SceneEditorContext(context, elts, this);
		edit.prefabPath = view.state.path;
		edit.properties = properties;
		edit.scene = scene;
		return edit;
	}

	// Override
	function getNewContextMenu(current: PrefabElement, ?onMake: PrefabElement->Void=null) : Array<hide.comp.ContextMenu.ContextMenuItem> {
		var newItems = new Array<hide.comp.ContextMenu.ContextMenuItem>();
		var allRegs = hrt.prefab.Library.getRegistered().copy();
		allRegs.remove("reference");
		var parent = current == null ? sceneData : current;
		var allowChildren = null;
		{
			var cur = parent;
			while( allowChildren == null && cur != null ) {
				allowChildren = cur.getHideProps().allowChildren;
				cur = cur.parent;
			}
		}
		for( ptype in allRegs.keys() ) {
			var pinf = allRegs.get(ptype);
			if( allowChildren != null && !allowChildren(ptype) ) {
				if( pinf.inf.allowParent == null || !pinf.inf.allowParent(parent) )
					continue;
			} else {
				if( pinf.inf.allowParent != null && !pinf.inf.allowParent(parent) )
					continue;
			}
			if(ptype == "shader")
				newItems.push(getNewShaderMenu(parent, onMake));
			else
				newItems.push(getNewTypeMenuItem(ptype, parent, onMake));
		}
		newItems.sort(function(l1,l2) return Reflect.compare(l1.label,l2.label));
		return newItems;
	}

	function getNewTypeMenuItem(ptype: String, parent: PrefabElement, onMake: PrefabElement->Void, ?label: String) : hide.comp.ContextMenu.ContextMenuItem {
		var pmodel = hrt.prefab.Library.getRegistered().get(ptype);
		return {
			label : label != null ? label : pmodel.inf.name,
			click : function() {
				function make(?path) {
					var p = Type.createInstance(pmodel.cl, [parent]);
					@:privateAccess p.type = ptype;
					if(path != null)
						p.source = path;
					autoName(p);
					if(onMake != null)
						onMake(p);
					return p;
				}

				if( pmodel.inf.fileSource != null )
					ide.chooseFile(pmodel.inf.fileSource, function(path) {
						if( path == null ) return;
						var p = make(path);
						addObject([p]);
					});
				else
					addObject([make()]);
			}
		};
	}

	function getNewShaderMenu(parentElt: PrefabElement, onMake: PrefabElement->Void) : hide.comp.ContextMenu.ContextMenuItem {
		var custom = getNewTypeMenuItem("shader", parentElt, onMake, "Custom...");

		function shaderItem(name, path) : hide.comp.ContextMenu.ContextMenuItem {
			return {
				label : name,
				click : function() {
					var s = new hrt.prefab.Shader(parentElt);
					s.source = path;
					s.name = name;
					addObject([s]);
				}
			}
		}

		var menu = [custom];

		var shaders : Array<String> = hide.Ide.inst.currentConfig.get("fx.shaders", []);
		for(path in shaders) {
			var name = path;
			if(StringTools.endsWith(name, ".hx")) {
				name = name.substr(0, -3);
				name = name.split("/").pop();
			}
			else {
				name = name.split(".").pop();
			}
			menu.push(shaderItem(name, path));
		}

		return {
			label: "Shaders",
			menu: menu
		};
	}

	public function getZ(x: Float, y: Float) {
		var offset = 1000;
		var ray = h3d.col.Ray.fromValues(x, y, offset, 0, 0, -1);
		var dist = projectToGround(ray);
		if(dist >= 0) {
			return offset - dist;
		}
		return 0.;
	}

	public function projectToGround(ray: h3d.col.Ray) {
		var minDist = -1.;
		var zPlane = h3d.col.Plane.Z(0);
		var pt = ray.intersect(zPlane);
		if(pt != null) {
			minDist = pt.sub(ray.getPos()).length();
		}
		return minDist;
	}

	public function screenToWorld(sx: Float, sy: Float) {
		var camera = scene.s3d.camera;
		var ray = camera.rayFromScreen(sx, sy);
		var dist = projectToGround(ray);
		if(dist >= 0) {
			return ray.getPoint(dist);
		}
		return null;
	}

	public function worldToScreen(wx: Float, wy: Float, wz: Float) {
		var camera = scene.s3d.camera;
		var pt = camera.project(wx, wy, wz, scene.s2d.width, scene.s2d.height);
		return new h2d.col.Point(pt.x, pt.y);
	}

	public function worldMat(?obj: Object, ?elt: PrefabElement) {
		if(obj != null) {
			if(obj.defaultTransform != null) {
				var m = obj.defaultTransform.clone();
				m.invert();
				m.multiply(m, obj.getAbsPos());
				return m;
			}
			else {
				return obj.getAbsPos().clone();
			}
		}
		else {
			var mat = new h3d.Matrix();
			mat.identity();
			var o = Std.downcast(elt, Object3D);
			while(o != null) {
				mat.multiply(mat, o.getTransform());
				o = o.parent.to(hrt.prefab.Object3D);
			}
			return mat;
		}
	}

	function editPivot() {
		if (curEdit.rootObjects.length == 1) {
			var ray = scene.s3d.camera.rayFromScreen(scene.s2d.mouseX, scene.s2d.mouseY);
			var polyColliders = new Array<PolygonBuffer>();
			var meshes = new Array<Mesh>();
			for (m in curEdit.rootObjects[0].getMeshes()) {
				var hmdModel = Std.downcast(m.primitive, HMDModel);
				if (hmdModel != null) {
					var optiCollider = Std.downcast(hmdModel.getCollider(), OptimizedCollider);
					var polyCollider = Std.downcast(optiCollider.b, PolygonBuffer);
					if (polyCollider != null) {
						polyColliders.push(polyCollider);
						meshes.push(m);
					}
				}
			}
			if (polyColliders.length > 0) {
				var pivot = getClosestVertex(polyColliders, meshes, ray);
				if (pivot != null) {
					pivot.elt = curEdit.rootElements[0];
					customPivot = pivot;
				} else {
					// mouse outside
				}
			} else {
				// no collider found
			}
		} else {
			throw "Can't edit when multiple objects are selected";
		}
	}

	function getClosestVertex( colliders : Array<PolygonBuffer>, meshes : Array<Mesh>, ray : Ray ) : CustomPivot {

		var best = -1.;
		var bestVertex : CustomPivot = null;
		for (idx in 0...colliders.length) {
			var c = colliders[idx];
			var m = meshes[idx];
			var r = ray.clone();
			r.transform(m.getInvPos());
			var rdir = new FPoint(r.lx, r.ly, r.lz);
			var r0 = new FPoint(r.px, r.py, r.pz);
			@:privateAccess var i = c.startIndex;
			@:privateAccess for( t in 0...c.triCount ) {
				var i0 = c.indexes[i++] * 3;
				var p0 = new FPoint(c.buffer[i0++], c.buffer[i0++], c.buffer[i0]);
				var i1 = c.indexes[i++] * 3;
				var p1 = new FPoint(c.buffer[i1++], c.buffer[i1++], c.buffer[i1]);
				var i2 = c.indexes[i++] * 3;
				var p2 = new FPoint(c.buffer[i2++], c.buffer[i2++], c.buffer[i2]);

				var e1 = p1.sub(p0);
				var e2 = p2.sub(p0);
				var p = rdir.cross(e2);
				var det = e1.dot(p);
				if( det < hxd.Math.EPSILON ) continue; // backface culling (negative) and near parallel (epsilon)

				var invDet = 1 / det;
				var T = r0.sub(p0);
				var u = T.dot(p) * invDet;

				if( u < 0 || u > 1 ) continue;

				var q = T.cross(e1);
				var v = rdir.dot(q) * invDet;

				if( v < 0 || u + v > 1 ) continue;

				var t = e2.dot(q) * invDet;

				if( t < hxd.Math.EPSILON ) continue;

				if( best < 0 || t < best ) {
					best = t;
					var ptIntersection = r.getPoint(t);
					var pI = new FPoint(ptIntersection.x, ptIntersection.y, ptIntersection.z);
					inline function distanceFPoints(a : FPoint, b : FPoint) : Float {
						var dx = a.x - b.x;
						var dy = a.y - b.y;
						var dz = a.z - b.z;
						return dx * dx + dy * dy + dz * dz;
					}
					var test0 = distanceFPoints(p0, pI);
					var test1 = distanceFPoints(p1, pI);
					var test2 = distanceFPoints(p2, pI);
					var locBestVertex : FPoint;
					if (test0 <= test1 && test0 <= test2) {
						locBestVertex = p0;
					} else if (test1 <= test0 && test1 <= test2) {
						locBestVertex = p1;
					} else {
						locBestVertex = p2;
					}
					bestVertex = { elt : null, mesh: m, locPos: new Vector(locBestVertex.x, locBestVertex.y, locBestVertex.z) };
				}
			}
		}
		return bestVertex;
	}

	static function getPivot(objects: Array<Object>) {
		if (customPivot != null) {
			return customPivot.mesh.localToGlobal(customPivot.locPos.clone());
		}
		var pos = new h3d.Vector();
		for(o in objects) {
			pos = pos.add(o.getAbsPos().getPosition());
		}
		pos.scale3(1.0 / objects.length);
		return pos;
	}

	public static function hasParent(elt: PrefabElement, list: Array<PrefabElement>) {
		for(p in list) {
			if(isParent(elt, p))
				return true;
		}
		return false;
	}

	public static function hasChild(elt: PrefabElement, list: Array<PrefabElement>) {
		for(p in list) {
			if(isParent(p, elt))
				return true;
		}
		return false;
	}

	public static function isParent(elt: PrefabElement, parent: PrefabElement) {
		var p = elt.parent;
		while(p != null) {
			if(p == parent) return true;
			p = p.parent;
		}
		return false;
	}

	static function getParentGroup(elt: PrefabElement) {
		while(elt != null) {
			if(elt.type == "object")
				return elt;
			elt = elt.parent;
		}
		return null;
	}
}