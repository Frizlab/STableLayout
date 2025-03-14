/*
 * STableLayout
 * STableItemAlignment.swift
 * https://github.com/ekazaev/ChatLayout
 *
 * Created by Eugene Kazaev in 2020-2022.
 * Distributed under the MIT license.
 */

import Foundation
import UIKit



/** Represent item alignment in collection view layout. */
public enum STableItemAlignment : Hashable {
	
	/** Should be aligned at the leading edge of the layout. That includes all the additional content offsets. */
	case leading
	
	/** Should be aligned at the center of the layout. */
	case center
	
	/** Should be aligned at the trailing edge of the layout. */
	case trailing
	
	/** Should be aligned using the full width of the available content width. */
	case fullWidth
	
}
