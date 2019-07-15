package hrt.prefab.rfx;

typedef BloomProps = {
	var size : Float;
	var threshold : Float;
	var intensity : Float;
	var blur : Float;
	var saturation : Float;
	var blurQuality : Float;
	var blurLinear : Float;
}

class Bloom extends RendererFX {

	var bloomPass = new h3d.pass.ScreenFx(new hrt.shader.Bloom());
	var bloomBlur = new h3d.pass.Blur();

	public function new(?parent) {
		super(parent);
		props = ({
			size : 0.5,
			blur : 3,
			intensity : 1.,
			threshold : 0.5,
			saturation: 0,
			blurQuality: 1.0,
			blurLinear : 0.0,
		} : BloomProps);
	}

	override function apply(r:h3d.scene.Renderer, step:h3d.impl.RendererFX.Step) {
		if( step == BeforeTonemapping ) {
			r.mark("Bloom");
			var pb : BloomProps = props;
			var bloom = r.allocTarget("bloom", false, pb.size, RGBA16F);
			var ctx = r.ctx;
			ctx.engine.pushTarget(bloom);
			bloomPass.shader.hdr = ctx.getGlobal("hdr");
			bloomPass.shader.threshold = pb.threshold;
			bloomPass.shader.intensity = pb.intensity;
			bloomPass.shader.colorMatrix.identity();
			bloomPass.shader.colorMatrix.colorSaturate(pb.saturation);
			bloomPass.render();
			ctx.engine.popTarget();

			bloomBlur.radius = pb.blur;
			bloomBlur.quality = pb.blurQuality;
			bloomBlur.linear = pb.blurLinear;
			bloomBlur.apply(ctx, bloom);
			ctx.setGlobal("bloom",bloom);
		}
	}

	#if editor
	override function edit( ctx : hide.prefab.EditContext ) {
		ctx.properties.add(new hide.Element('
			<dl>
			<dt>Intensity</dt><dd><input type="range" min="0" max="2" field="intensity"/></dd>
			<dt>Threshold</dt><dd><input type="range" min="0" max="1" field="threshold"/></dd>
			<dt>Size</dt><dd><input type="range" min="0" max="1" field="size"/></dd>
			<dt>Blur</dt><dd><input type="range" min="0" max="20" field="blur"/></dd>
			<dt>Saturation</dt><dd><input type="range" min="-1" max="1" field="saturation"/></dd>
			<dt>Blur Quality</dt><dd><input type="range" min="0" max="1" field="blurQuality"/></dd>
			<dt>Blur Linear</dt><dd><input type="range" min="0" max="1" field="blurLinear"/></dd>
			</dl>
		'),props);
	}
	#end

	static var _ = Library.register("rfx.bloom", Bloom);

}