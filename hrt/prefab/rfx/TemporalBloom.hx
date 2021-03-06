package hrt.prefab.rfx;

import hxsl.Eval;
import h3d.pass.Copy;

class Temporal extends h3d.shader.ScreenShader {

	static var SRC = {

		@param var cur : Sampler2D;
		@param var prev : Sampler2D;
		@param var prevCamMat : Mat4;
		@param var cameraInverseViewProj : Mat4;
		@ignore @param var depthMap : Channel;
		@param var strength : Float;

		function getPixelPosition( uv : Vec2 ) : Vec3 {
			var depth = depthMap.get(uv);
			var temp = vec4(uvToScreen(uv), depth, 1) * cameraInverseViewProj;
			var originWS = temp.xyz / temp.w;
			return originWS;
		}

		function fragment() {
			var pixelPos = getPixelPosition(calculatedUV);
			var prevPos =  vec4(pixelPos, 1.0) * prevCamMat;
			prevPos.xyz /= prevPos.w;
			var prevUV = screenToUv(prevPos.xy);
			var prevPixelPos = getPixelPosition(prevUV);
			var dist = (pixelPos - prevPixelPos).length();

			var curVal = cur.get(calculatedUV).rgb;
			if( prevUV.x > 1.0 || prevUV.x < 0.0 || prevUV.y > 1.0 || prevUV.y < 0.0 || dist > 1.0 ) {
				pixelColor.rgb = curVal;
			}
			else {
				var prevVal = prev.get(prevUV).rgb;
			pixelColor.rgb = mix(curVal, prevVal, strength);
			}
		}
	};
}

class DualFilterDown extends h3d.shader.ScreenShader {

	static var SRC = {

		@param var source : Sampler2D;
		@param var halfPixel : Vec2;

		function fragment() {
			var sum = vec3(0,0,0);
			sum += texture(source, calculatedUV).rgb * 4.0;
			sum += texture(source, calculatedUV + halfPixel.xy).rgb;
			sum += texture(source, calculatedUV - halfPixel.xy).rgb;
			sum += texture(source, calculatedUV + vec2(halfPixel.x, -halfPixel.y)).rgb;
			sum += texture(source, calculatedUV - vec2(halfPixel.x, -halfPixel.y)).rgb;
			pixelColor.rgb = sum / 8.0;
		}
	};
}

class DualFilterUp extends h3d.shader.ScreenShader {

	static var SRC = {

		@param var source : Sampler2D;
		@param var halfPixel : Vec2;
		
		function fragment() {
			var sum = vec3(0,0,0);
			sum += texture(source, calculatedUV + vec2(-halfPixel.x * 2.0, 0.0)).rgb;
			sum += texture(source, calculatedUV + vec2(-halfPixel.x, halfPixel.y)).rgb * 2.0;
			sum += texture(source, calculatedUV + vec2(0.0, halfPixel.y * 2.0)).rgb;
			sum += texture(source, calculatedUV + vec2(halfPixel.x, halfPixel.y)).rgb * 2.0;
			sum += texture(source, calculatedUV + vec2(halfPixel.x * 2.0, 0.0)).rgb;
			sum += texture(source, calculatedUV + vec2(halfPixel.x, -halfPixel.y)).rgb * 2.0;
			sum += texture(source, calculatedUV + vec2(0.0, -halfPixel.y * 2.0)).rgb;
			sum += texture(source, calculatedUV + vec2(-halfPixel.x, -halfPixel.y)).rgb * 2.0;
			pixelColor.rgb = sum / 12.0;
		}
	};
}

class Threshold extends h3d.shader.ScreenShader {

	static var SRC = {

		@param var hdr : Sampler2D;
		@param var threshold : Float;
        @param var intensity : Float;

		@const var USE_TEMPORAL_FILTER : Bool;
		@const var PREVENT_GHOSTING : Bool;
		@param var cur : Sampler2D;
		@param var prev : Sampler2D;
		@param var prevCamMat : Mat4;
		@param var cameraInverseViewProj : Mat4;
		@ignore @param var depthMap : Channel;
		@param var strength : Float;

		function getPixelPosition( uv : Vec2 ) : Vec3 {
			var depth = depthMap.get(uv);
			var temp = vec4(uvToScreen(uv), depth, 1) * cameraInverseViewProj;
			var originWS = temp.xyz / temp.w;
			return originWS;
		}

		function fragment() {
			var curVal = max(hdr.get(calculatedUV).rgb - threshold, 0.0) * intensity;
			pixelColor.rgb = curVal;

			if( USE_TEMPORAL_FILTER ) {
				var pixelPos = getPixelPosition(calculatedUV);
				var prevPos =  vec4(pixelPos, 1.0) * prevCamMat;
				prevPos.xyz /= prevPos.w;
				var prevUV = screenToUv(prevPos.xy);
				
				if( prevUV.x <= 1.0 && prevUV.x >= 0.0 && prevUV.y <= 1.0 && prevUV.y >= 0.0 ) {
					var prevVal = prev.get(prevUV).rgb;
					pixelColor.rgb = mix(curVal, prevVal, strength);
				}
			}
		}
	};
}

typedef TemporalBloomProps = {
	var size : Float;
	var downScaleCount : Int;
	var threshold : Float;
    var intensity : Float;
	var useTemporalFilter : Bool;
	var temporalStrength : Float;
}

class TemporalBloom extends RendererFX {

	var thresholdPass = new h3d.pass.ScreenFx(new Threshold());
	var temporalPass = new h3d.pass.ScreenFx(new Temporal());
	var downScale = new h3d.pass.ScreenFx(new DualFilterDown());
	var upScale = new h3d.pass.ScreenFx(new DualFilterUp());

	var prevResult : h3d.mat.Texture;
	var prevCamMat : h3d.Matrix;

	public function new(?parent) {
		super(parent);
		props = ({
			size : 0.5,
			downScaleCount : 5,
			threshold : 0.5,
            intensity : 1.0,
			useTemporalFilter : true,
			temporalStrength : 0,
		} : TemporalBloomProps);
		prevCamMat = new h3d.Matrix();
		prevCamMat.identity();
	}

	override function apply(r:h3d.scene.Renderer, step:h3d.impl.RendererFX.Step) {
		if( step == BeforeTonemapping ) {
			r.mark("TBloom");
			var pb : TemporalBloomProps = props;
			var ctx = r.ctx;

			var source = r.allocTarget("source", false, pb.size, RGBA16F);
			ctx.engine.pushTarget(source);
			thresholdPass.shader.hdr = ctx.getGlobal("hdr");
			thresholdPass.shader.threshold = pb.threshold;
            thresholdPass.shader.intensity = pb.intensity;
			if( pb.useTemporalFilter ) {
				thresholdPass.shader.USE_TEMPORAL_FILTER = true;
				var depth : hxsl.ChannelTexture = ctx.getGlobal("depthMap");
				prevResult = r.allocTarget("pr", false, pb.size, RGBA16F);
				thresholdPass.shader.depthMapChannel = depth.channel;
				thresholdPass.shader.depthMap = depth.texture;
				thresholdPass.shader.prev = prevResult;
				thresholdPass.shader.prevCamMat.load(prevCamMat);
				thresholdPass.shader.cameraInverseViewProj.load(ctx.camera.getInverseViewProj());
				thresholdPass.shader.strength = pb.temporalStrength;
				thresholdPass.render();
				ctx.engine.popTarget();
				Copy.run(source, prevResult);
				prevCamMat.load(ctx.camera.m);
			}
			else {
				thresholdPass.shader.USE_TEMPORAL_FILTER = false;
				thresholdPass.render();
				ctx.engine.popTarget();
			}
				
			var curSize = pb.size;
			var curTarget : h3d.mat.Texture = source;
			for( i in 0 ... pb.downScaleCount ) {
				curSize *= 0.5;
				var prevTarget = curTarget;
				curTarget = r.allocTarget("dso_"+i, false, curSize, RGBA16F);
				ctx.engine.pushTarget(curTarget);
				downScale.shader.source = prevTarget;
				downScale.shader.halfPixel.set(1.0 / prevTarget.width, 1.0 / prevTarget.height);
				downScale.render();
				ctx.engine.popTarget();
			}
			for( i in 0 ... pb.downScaleCount ) {
				curSize *= 1.5;
				var prevTarget = curTarget;
				curTarget = r.allocTarget("uso_"+i, false, curSize, RGBA16F);
				ctx.engine.pushTarget(curTarget);
				upScale.shader.source = prevTarget;
				upScale.shader.halfPixel.set(1.0 / prevTarget.width, 1.0 / prevTarget.height);
				upScale.render();
				ctx.engine.popTarget();
			}

			ctx.setGlobal("bloom", curTarget);
		}
	}

	#if editor
	override function edit( ctx : hide.prefab.EditContext ) {
		ctx.properties.add(new hide.Element('
		<div class="group" name="Bloom">
			<dl>
				<dt>Threshold</dt><dd><input type="range" min="0" max="1" field="threshold"/></dd>
				<dt>Intensity</dt><dd><input type="range" min="0" max="1" field="intensity"/></dd>
				<dt>Texture Size</dt><dd><input type="range" min="0" max="1" field="size"/></dd>
				<dt>DownScale/UpScale Count</dt><dd><input type="range" min="1" max="5" field="downScaleCount" step="1"/></dd>
			</dl>
		</div>
		<div class="group" name="Temporal Filtering">
			<dl>
			<dt>Enable</dt><dd><input type="checkbox" field="useTemporalFilter"/></dd>
			<dt>Strength</dt><dd><input type="range" min="0" max="1" field="temporalStrength"/></dd>
			</dl>
		</div>
		'),props);
	}
	#end

	static var _ = Library.register("rfx.temporalbloom", TemporalBloom);

}