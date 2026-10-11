import React from 'react';
import {Composition} from 'remotion';
import {Title} from './Title';
import {Team} from './Team';
import {Problem} from './Problem';
import {Arch} from './Arch';
import {End} from './End';

// 長度（影格，30fps）要和 build.py 的片段長度一致
export const DUR = {Title: 150, Team: 610, Problem: 300, Arch: 405, End: 240};

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="Title" component={Title} durationInFrames={DUR.Title} fps={30} width={1920} height={1080} defaultProps={{total: DUR.Title}} />
    <Composition id="Team" component={Team} durationInFrames={DUR.Team} fps={30} width={1920} height={1080} defaultProps={{total: DUR.Team}} />
    <Composition id="Problem" component={Problem} durationInFrames={DUR.Problem} fps={30} width={1920} height={1080} defaultProps={{total: DUR.Problem}} />
    <Composition id="Arch" component={Arch} durationInFrames={DUR.Arch} fps={30} width={1920} height={1080} defaultProps={{total: DUR.Arch}} />
    <Composition id="End" component={End} durationInFrames={DUR.End} fps={30} width={1920} height={1080} defaultProps={{total: DUR.End}} />
  </>
);
