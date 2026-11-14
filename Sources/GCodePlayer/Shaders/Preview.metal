#include <metal_stdlib>
using namespace metal;
struct Instance { float4 a,b,color,timing; };
struct Uniforms { float4x4 vp,lightVP; float4 head,eye,clock; };
struct Out { float4 position [[position]]; float3 world,normal; float4 color; float kind,heat; float4 lightPosition; };
vertex Out bead(uint vid [[vertex_id]],uint instance [[instance_id]],constant Instance *segments [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    Instance s=segments[instance];
    float3 a=s.a.xyz,b=s.b.xyz;
    if(s.timing.w==2) { a+=u.head.xyz;b+=u.head.xyz; }
    if(s.timing.w==0 && u.clock.x<s.timing.y) b=mix(a,b,clamp((u.clock.x-s.timing.x)/max(.00001f,s.timing.y-s.timing.x),0.f,1.f));
    float heat=s.timing.w==0 && u.clock.z>0 ? exp(-max(0.f,u.clock.x-s.timing.y)/max(1.f,u.clock.y)*2.5f):0;
    if(s.timing.w==0 && u.clock.z>0) {
        float3 direction=normalize(b-a+float3(.000001,0,0));
        // Small bead overlap closes seams without allocating new join geometry.
        a-=direction*.018;b+=direction*.018;s.a.w*=1.10+heat*.025;s.b.w*=1.18-heat*.10;
    }
    float3 along=normalize(b-a+float3(.000001,0,0)),side=normalize(cross(along,float3(0,1,0)));
    float3 up=normalize(cross(side,along));
    constexpr float2 ring[8]={float2(-1,-.5),float2(-.75,-1),float2(.75,-1),float2(1,-.5),float2(1,.5),float2(.75,1),float2(-.75,1),float2(-1,.5)};
    constexpr float2 roundRing[8]={float2(-1,0),float2(-.7071,-.7071),float2(0,-1),float2(.7071,-.7071),float2(1,0),float2(.7071,.7071),float2(0,1),float2(-.7071,.7071)};
    float3 world,normal;
    if(u.clock.w>0) {
        constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[vid%6];
        float crossSection=c>=2?1.f:-1.f;
        world=(c%2==0?a:b);
        if(vid<6) {world+=side*crossSection*s.a.w*.5+up*s.b.w*.5;normal=up;}
        else {world+=up*crossSection*s.b.w*.5;normal=side;}
    } else if(vid<48) {
        uint face=vid/6,k=vid%6;constexpr uint corner[6]={0,1,2,2,1,3};uint c=corner[k],r=(face+(c>=2?1:0))%8;
        float2 profile=ring[r];
        if(s.timing.w==0) {
            profile=roundRing[r];
            // Cooling retains the expanded, contacting cross-section. Fresh material
            // is round; settled material relaxes to a rounded fused bead profile.
            if(u.clock.z>0) profile=sign(profile)*pow(abs(profile),float2(mix(.58f,1.f,heat)));
        }
        world=(c%2==0?a:b)+side*profile.x*s.a.w*.5+up*profile.y*s.b.w*.5;
        float2 n=normalize(float2(ring[(face+1)%8].y-ring[face].y,ring[face].x-ring[(face+1)%8].x));normal=s.timing.w==0?normalize(side*profile.x+up*profile.y):normalize(side*n.x+up*n.y);
    } else {
        // End caps, two triangles per end.
        uint k=(vid-48)%6;constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[k];float2 r=float2(c>=2?1:-1,c%2==0?-1:1);
        if(s.timing.w==0) r*=.70f;bool end=vid>=54;world=(end?b:a)+side*r.x*s.a.w*.5+up*r.y*s.b.w*.5;normal=end?along:-along;
    }
    return {u.vp*float4(world,1),world,normal,s.color,s.timing.w,heat,u.lightVP*float4(world,1)};
}
// Screen-facing elliptical ribbon: two triangles for distant beads instead of
// generating the complete tube. Lighting normals retain a rounded appearance.
vertex Out ribbon(uint vid [[vertex_id]],uint instance [[instance_id]],constant Instance *segments [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
    Instance s=segments[instance];float3 a=s.a.xyz,b=s.b.xyz;
    if(u.clock.x<s.timing.y)b=mix(a,b,clamp((u.clock.x-s.timing.x)/max(.00001f,s.timing.y-s.timing.x),0.f,1.f));
    float3 along=normalize(b-a+float3(.000001,0,0)),horizontal=normalize(cross(along,float3(0,1,0))),up=normalize(cross(horizontal,along));
    float3 facing=normalize(u.eye.xyz-(a+b)*.5),side=normalize(cross(along,facing));
    float radius=.5*length(float2(dot(side,horizontal)*s.a.w,dot(side,up)*s.b.w));
    if(u.clock.z>0)radius*=1.12;
    constexpr uint corners[6]={0,1,2,2,1,3};uint c=corners[vid];float sign=c>=2?1.f:-1.f;
    float3 world=(c%2==0?a:b)+side*(sign*radius),normal=normalize(facing*.6+side*sign*.8);
    return {u.vp*float4(world,1),world,normal,s.color,0,0,u.lightVP*float4(world,1)};
}
fragment float4 shaded(Out in [[stage_in]],constant Uniforms &u [[buffer(1)]],depth2d<float> shadowMap [[texture(0)]]) {
    float3 base=in.color.rgb,n=normalize(in.normal),v=normalize(u.eye.xyz-in.world),l=normalize(float3(-.4,1,.5));
    if(in.kind==1 && n.y>.5) {
        float2 p=in.world.xz/10,deriv=max(fwidth(p),float2(.0001));float2 grid=abs(fract(p-.5)-.5)/deriv;float line=1-min(min(grid.x,grid.y),1.f);base=mix(base,float3(.018,.027,.03),line*.45);
    }
    float visibility=1;
    if(u.head.w>0) {
        float3 p=in.lightPosition.xyz/in.lightPosition.w;float2 uv=float2(p.x*.5+.5,.5-p.y*.5);
        constexpr sampler shadowSampler(coord::normalized,filter::linear,compare_func::less_equal,address::clamp_to_edge);
        if(all(uv>0.f)&&all(uv<1.f)&&p.z>0&&p.z<1){
            float bias=max(.00025f,.001f*(1-dot(n,l)));visibility=0;
            if(u.head.w<.75) visibility=shadowMap.sample_compare(shadowSampler,uv,p.z-bias);
            else for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++)visibility+=shadowMap.sample_compare(shadowSampler,uv+float2(x,y)/float2(shadowMap.get_width(),shadowMap.get_height()),p.z-bias)/9.f;
            visibility=mix(.35f,1.f,visibility);
        }
    }
    float diffuse=max(dot(n,l),0.f)*visibility,spec=pow(max(dot(n,normalize(l+v)),0.f),in.kind==1?8.f:mix(70.f,110.f,in.heat));
    float rim=pow(1-max(dot(n,v),0.f),3.f)*max(dot(n,normalize(float3(.6,.5,-1))),0.f);
    float3 color=base*(.28+1.7*diffuse+rim*.2)+spec*visibility*(in.kind==1?.006:mix(.25,.5,in.heat));
    color=color/(1+color);color=pow(max(color,0.f),float3(1/2.2f));return float4(color,in.color.a);
}
