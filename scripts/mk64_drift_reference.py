#!/usr/bin/env python3
"""Run original C drift routines in isolation; development oracle, never game code.
Usage: python3 scripts/mk64_drift_reference.py ~/Work/mk64
Matrix transform is identity so outputs are local forces. Audio is stubbed.
"""
import pathlib, subprocess, sys, tempfile, re
source = (pathlib.Path(sys.argv[1]) / 'src/player_controller.c').read_text()
def function(name, source=source):
    start = re.search(r'^(?:void|bool) ' + name + r'\(', source, re.M).start()
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
preamble = '''
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
typedef uint32_t u32; typedef float f32; typedef double f64; typedef int32_t s32; typedef int16_t s16; typedef int8_t s8;
typedef float Vec3f[3];
#define UNUSED
#define DEGREES(x) (182*(x))
enum { LOST_RACE_EFFECT=1, AB_SPIN_EFFECT=2, DRIFTING_EFFECT=4, HOP_EFFECT=8,
BANANA_NEAR_SPINOUT_EFFECT=16, STAR_EFFECT=32, DRIFT_OUTSIDE_EFFECT=64,
DRIVING_NEAR_SPINOUT=1, PLAYER_CPU=1, PLAYER_HUMAN=2, BATTLE=1 };
typedef struct { unsigned effects,kartProps,type; float speed,unk_208,unk_20C,unk_084,unk_090,currentSpeed;
u32 steerChangeIncrement; int steerPosition,steerPositionDelta,driftStateCounter,driftState,unk_0C0;
short unk_078,rotation[3]; float orientationMatrix[3][3]; } Player;
typedef struct { short unk_2C,unk_B0; } Camera;
int gModeSelection=0;
void mtxf_transform_vec3f_mat3(float *v, float m[3][3]) {}
void func_800C9060(int a,int b) {}
#define STUB(name) void name(Player*p,Vec3f a,Vec3f b) {}
STUB(func_800378E8) STUB(func_80037A4C) STUB(func_80037614) STUB(func_8003777C)
'''
steering_calls = '\n'.join(line for line in function('func_80033AE0').splitlines()
    if line.strip().startswith(('update_steering_large(', 'update_steering_small(')))
steering_wrapper = """
void reference_steer(Player *player, int desired) {
s32 steer_position=player->steerPosition;
player->steerPosition=desired*65536;
s32 steer_position_delta=(steer_position-player->steerPosition)>>16;
s32 steer_resistance_large_turn=6,steer_resistance_small_turn=9;
""" + steering_calls + "\nplayer->steerPosition=steer_position;}"
camera_source=(pathlib.Path(sys.argv[1])/'src/camera.c').read_text()
render_source=(pathlib.Path(sys.argv[1])/'src/render_player.c').read_text()
camera_prefix=function('func_8001E45C',camera_source).split('    if (((player->effects & BANANA_SPINOUT_EFFECT)')[0]
camera_wrapper=camera_prefix.replace('func_8001E45C','reference_camera')+'adjust_angle(&camera->unk_2C,(s16)(player->rotation[1]+camera->unk_B0),var_a3);}'
main = '''
int main(void) {
{Player p={0};Camera c={3000,0};p.rotation[1]=4000;p.unk_078=265;
for(int t=0;t<20;t++) {
p.effects=t<10?DRIFTING_EFFECT|DRIFT_OUTSIDE_EFFECT:0;
reference_camera(&c,&p,0);
if(t==0||t==9||t==10||t==19)printf("camera tick=%d -> angle=%d offset=%d\\n",t+1,c.unk_2C,c.unk_B0);
}}

{ Player p={0};for(int t=0;t<90;t++) {
int outside=(t>=20 && t<45)||(t>=55 && t<80);
reference_steer(&p,outside?-53:53);
if(t==0||t==19||t==44||t==54||t==79||t==89)
printf("steering tick=%d -> position=%d increment=%u lateral=%.6f\\n",t+1,p.steerPosition,p.steerChangeIncrement,p.unk_090);
}}
for(int sign=-1;sign<=1;sign+=2) for(int outside=0;outside<=1;outside++) for(int count=20;count<=100;count+=80) {
Player p={0}; p.effects=DRIFTING_EFFECT | (outside ? DRIFT_OUTSIDE_EFFECT:0);
p.speed=5.5f;p.currentSpeed=310;p.unk_208=28;p.unk_084=-15;p.unk_090=-59.85f;
p.unk_078=sign*265;p.driftStateCounter=count;Vec3f out={0};func_80037BB4(&p,out);
printf("yaw=%d outside=%d counter=%d -> rotation=%d local_force=(%.6f,%.6f)\\n",sign*265,outside,count,p.rotation[1],out[0],out[2]);
}
for(int sign=-1;sign<=1;sign+=2) {
Player p={0};p.unk_0C0=sign*20*182;
for(int cycle=0;cycle<2;cycle++) {
p.steerPosition=-sign*53*65536;
for(int t=0;t<18;t++)update_drift_state_counter(&p,0);
p.steerPosition=sign*53*65536;update_drift_state_counter(&p,0);
printf("side=%d cycle=%d -> charge=%d counter=%d\\n",sign,cycle+1,p.driftState,p.driftStateCounter);
}}
}
'''
with tempfile.TemporaryDirectory() as tmp:
    c=pathlib.Path(tmp)/'oracle.c';exe=pathlib.Path(tmp)/'oracle'
    c.write_text(preamble+'\n'.join(function(n) for n in ['func_80036DB4','func_800371F4','func_80037BB4','update_drift_state_counter','func_80033850','update_steering_large','update_steering_small'])+steering_wrapper+function('adjust_angle',render_source)+function('move_s16_towards',render_source)+camera_wrapper+main)
    subprocess.run(['cc','-O0','-w',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
